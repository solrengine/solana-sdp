# frozen_string_literal: true

require "net/http"
require "json"
require "uri"

require_relative "errors"

module Sdp
  # Zero-dependency Net::HTTP request core for the SDP API.
  #
  # Success envelope:  { "data": ..., "meta": ... }
  # Error envelope:    { "error": { "code", "message", "details" }, "meta": ... }
  #
  # Retry policy: GETs retry once on Timeout/Unavailable. POSTs NEVER retry —
  # SDP has no idempotency key, so re-sending a transfer risks a double-spend.
  #
  # Endpoint methods live in resource modules layered on top of the #get/#post
  # primitives below; this class owns auth, envelope handling, the typed error
  # mapping, and the retry posture.
  class Client
    DEFAULT_BASE_URL = "http://127.0.0.1:8787"
    OPEN_TIMEOUT = 2  # seconds — fail fast when the stack isn't up
    READ_TIMEOUT = 10 # seconds — transfer confirmation is synchronous

    # Wallet-scoped API keys return 404 (not 403) for wallets outside their
    # scope, which reads like "does not exist" when it really means "not
    # yours". Appended to every NotFound so the failure is diagnosable.
    NOT_FOUND_HINT = "(hint: wallet-scoped API keys return 404 for wallets outside their scope)"

    # Request-layer result: the unwrapped envelope `data` plus `meta`.
    # Resource methods generally return data to callers; pagination needs
    # meta (hasMore/page), so the request layer always carries both.
    Response = Struct.new(:data, :meta, keyword_init: true)

    attr_reader :base_url

    def initialize(base_url: ENV.fetch("SDP_API_BASE_URL", DEFAULT_BASE_URL),
                   api_key: ENV["SDP_API_KEY"],
                   open_timeout: OPEN_TIMEOUT,
                   read_timeout: READ_TIMEOUT)
      if api_key.to_s.strip.empty?
        raise ConfigurationError, "SDP_API_KEY is missing or blank. " \
          "Pass api_key: or set the SDP_API_KEY environment variable."
      end

      @base_url = base_url.to_s.chomp("/")
      @api_key = api_key
      @open_timeout = open_timeout
      @read_timeout = read_timeout
    end

    # Request primitives — the internal API the resource modules build on.
    # Both return a Response(data:, meta:) with recursively snake_cased
    # symbol keys, or raise a typed Sdp::Error.

    # Reads are safe to retry exactly once on transport-level failures.
    def get(path, query: nil)
      uri = build_uri(path, query)
      with_read_retry do
        perform(Net::HTTP::Get.new(uri), uri)
      end
    end

    def post(path, payload = nil)
      uri = build_uri(path, nil)
      request = Net::HTTP::Post.new(uri)
      request["Content-Type"] = "application/json"
      request.body = JSON.generate(payload) unless payload.nil?
      perform(request, uri) # no retry wrapper — writes are never retried
    end

    private

    def with_read_retry
      attempts = 0
      begin
        attempts += 1
        yield
      rescue Sdp::Timeout, Sdp::Unavailable
        retry if attempts < 2
        raise
      end
    end

    def perform(request, uri)
      request["Authorization"] = "Bearer #{@api_key}"
      request["Accept"] = "application/json"

      response = Net::HTTP.start(
        uri.host, uri.port,
        use_ssl: uri.scheme == "https",
        open_timeout: @open_timeout,
        read_timeout: @read_timeout
      ) { |http| http.request(request) }

      handle(response)
    rescue Net::OpenTimeout => e
      # The TCP connection never opened — the request was definitely not
      # sent, so this is "unreachable" (safe to retry/fall back), never the
      # unknown-outcome Timeout that triggers transfer reconciliation.
      raise Sdp::Unavailable.new("SDP unreachable (connect timeout): #{e.message}", http_status: nil)
    rescue Net::ReadTimeout => e
      raise Sdp::Timeout.new("SDP request timed out: #{e.message}", http_status: nil)
    rescue Errno::ECONNREFUSED, Errno::ECONNRESET, Errno::EHOSTUNREACH, SocketError, EOFError => e
      raise Sdp::Unavailable.new("SDP unreachable: #{e.message}", http_status: nil)
    end

    def build_uri(path, query)
      uri = URI.parse("#{@base_url}#{path}")
      if query
        compacted = query.compact
        uri.query = URI.encode_www_form(compacted) unless compacted.empty?
      end
      uri
    end

    def handle(response)
      status = response.code.to_i
      body = parse_body(response.body)

      # HTTP 202 is SDP's "accepted, awaiting signatures" response. It is in
      # the 2xx range but carries the ERROR envelope, so it must be handled
      # before the success branch or it silently parses as a success.
      raise_typed_error(status, body) if status == 202

      if (200..299).cover?(status)
        data = body.is_a?(Hash) && body.key?("data") ? body["data"] : body
        meta = body.is_a?(Hash) ? body["meta"] : nil
        return Response.new(data: symbolize(data), meta: symbolize(meta))
      end

      raise_typed_error(status, body)
    end

    def parse_body(raw)
      return nil if raw.nil? || raw.empty?
      JSON.parse(raw)
    rescue JSON::ParserError
      nil
    end

    def raise_typed_error(status, body)
      error = body.is_a?(Hash) ? body["error"] : nil
      code = error.is_a?(Hash) ? error["code"] : nil
      message = (error.is_a?(Hash) && error["message"]) || "SDP request failed (HTTP #{status})"
      details = error.is_a?(Hash) ? symbolize(error["details"]) : nil
      meta = body.is_a?(Hash) ? symbolize(body["meta"]) : nil

      klass = error_class_for(status, code)
      message = "#{message} #{NOT_FOUND_HINT}" if klass <= Sdp::NotFound
      raise klass.new(message, code: code, http_status: status, details: details, meta: meta)
    end

    # Code takes precedence over status; status is the fallback. A 5xx that
    # doesn't carry SDP's error shape is treated as Unavailable (proxy error,
    # crash page, etc.) so GETs can retry it.
    def error_class_for(status, code)
      case code
      when "UNAUTHORIZED"               then return Sdp::Unauthorized
      when "INSUFFICIENT_PERMISSIONS"   then return Sdp::InsufficientPermissions
      when "FORBIDDEN"                  then return Sdp::Forbidden
      when "TRANSACTION_FAILED"         then return Sdp::TransactionFailed
      when "RATE_LIMITED"               then return Sdp::RateLimited
      when "NOT_FOUND"                  then return Sdp::NotFound
      when "CONFLICT"                   then return Sdp::Conflict
      when "SIGNING_PENDING"            then return Sdp::SigningPending
      when "BAD_REQUEST", "VALIDATION_ERROR" then return Sdp::BadRequest
      end

      case status
      when 202 then Sdp::SigningPending
      when 401 then Sdp::Unauthorized
      when 403 then Sdp::Forbidden
      when 404 then Sdp::NotFound
      when 409 then Sdp::Conflict
      when 429 then Sdp::RateLimited
      when 400..499 then Sdp::BadRequest
      when 500..599 then Sdp::Unavailable
      else Sdp::Error
      end
    end

    # camelCase JSON → snake_case symbol keys, recursively.
    def symbolize(value)
      case value
      when Hash  then value.each_with_object({}) { |(k, v), h| h[underscore_key(k)] = symbolize(v) }
      when Array then value.map { |v| symbolize(v) }
      else value
      end
    end

    def underscore_key(key)
      key.to_s.gsub(/([a-z\d])([A-Z])/, '\1_\2').downcase.to_sym
    end
  end
end
