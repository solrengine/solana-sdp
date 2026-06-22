# frozen_string_literal: true

require "net/http"
require "openssl"
require "json"
require "uri"
require "bigdecimal"

require_relative "errors"
require_relative "pagination"
require_relative "resources/wallets"
require_relative "resources/payments"
require_relative "resources/issuance"
require_relative "resources/ramps"

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
    include Resources::Wallets
    include Resources::Payments
    include Resources::Issuance
    include Resources::Ramps

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

    attr_reader :base_url, :custody_provider

    def initialize(base_url: ENV.fetch("SDP_API_BASE_URL", DEFAULT_BASE_URL),
                   api_key: ENV["SDP_API_KEY"],
                   custody_provider: ENV["SDP_CUSTODY_PROVIDER"],
                   open_timeout: OPEN_TIMEOUT,
                   read_timeout: READ_TIMEOUT)
      # Strip first, then guard: an ENV key with a trailing newline passes a
      # naive blank-check but then makes every request raise a raw ArgumentError
      # from the "Bearer …\n" header. Normalize once, at the boundary.
      @api_key = api_key.to_s.strip
      if @api_key.empty?
        raise ConfigurationError, "SDP_API_KEY is missing or blank. " \
          "Pass api_key: or set the SDP_API_KEY environment variable."
      end

      @base_url = base_url.to_s.chomp("/")
      # base_url is documented as ConfigurationError-covered, so validate it at
      # boot (mirroring the api_key fail-fast) instead of letting an unusable
      # URL surface as a cryptic transport error on the first request.
      parsed = begin
        URI.parse(@base_url)
      rescue URI::InvalidURIError
        nil
      end
      unless parsed.is_a?(URI::HTTP) && !parsed.host.to_s.empty?
        raise ConfigurationError, "SDP_API_BASE_URL is invalid: expected an http(s) URL with a " \
          "host, got #{@base_url.inspect}. Pass base_url: or set the SDP_API_BASE_URL environment variable."
      end

      # The default custody provider for wallet operations, configured once here
      # (or via SDP_CUSTODY_PROVIDER) so callers don't repeat provider: on every
      # create_wallet/initialize_custody. Blank → nil (fall through to SDP's own
      # default). This is what makes the ProviderCapabilityError hint actionable.
      provider = custody_provider.to_s.strip
      @custody_provider = provider.empty? ? nil : provider

      @open_timeout = open_timeout
      @read_timeout = read_timeout
    end

    # Redacted on purpose: the API key is a bearer secret and must never leak
    # into consoles, logs, or exception-capture payloads via the default
    # #inspect (which would dump every instance variable, @api_key included).
    def inspect
      "#<#{self.class} base_url=#{@base_url.inspect}>"
    end

    # Request primitives — the internal API the resource modules build on.
    # Both return a Response(data:, meta:) with recursively snake_cased
    # symbol keys, or raise a typed Sdp::Error.

    # Reads are safe to retry exactly once on transport-level failures.
    def get(path, query: nil)
      uri = build_uri(path, query)
      with_read_retry do
        perform(Net::HTTP::Get.new(uri), uri, idempotent: true)
      end
    end

    def post(path, payload = nil)
      uri = build_uri(path, nil)
      request = Net::HTTP::Post.new(uri)
      request["Content-Type"] = "application/json"
      request.body = JSON.generate(payload) unless payload.nil?
      perform(request, uri, idempotent: false) # no retry wrapper — writes are never retried
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

    # idempotent: is the safety hinge. A GET can be re-sent freely, so any
    # transport failure on it is "unreachable" (Unavailable, retryable). A POST
    # has no upstream idempotency key, so once the socket was live we cannot
    # know whether the transfer was processed — those failures must surface as
    # the unknown-outcome Timeout (reconcile before re-sending), never as a
    # retryable Unavailable that would risk a double-spend.
    def perform(request, uri, idempotent:)
      request["Authorization"] = "Bearer #{@api_key}"
      request["Accept"] = "application/json"

      response = Net::HTTP.start(
        uri.host, uri.port,
        use_ssl: uri.scheme == "https",
        open_timeout: @open_timeout,
        read_timeout: @read_timeout
      ) { |http| http.request(request) }

      handle(response, uri.path)
    rescue Net::OpenTimeout => e
      # The TCP connection never opened — the request was definitely not
      # sent, so this is "unreachable" (safe to retry/fall back), never the
      # unknown-outcome Timeout that triggers transfer reconciliation. Holds
      # for POSTs too: nothing crossed the wire.
      raise Sdp::Unavailable.new("SDP unreachable (connect timeout): #{e.message}", http_status: nil)
    rescue Net::ReadTimeout => e
      # The request was fully sent and we timed out awaiting the response —
      # the outcome is unknown for everyone, so always Timeout.
      raise Sdp::Timeout.new("SDP request timed out: #{e.message}", http_status: nil)
    rescue Errno::ECONNREFUSED, Errno::EHOSTUNREACH, SocketError,
           OpenSSL::SSL::SSLError, Errno::ETIMEDOUT => e
      # Connection never established / DNS failure / TLS handshake failure /
      # connect-phase timeout — all provably pre-send, so the request was not
      # processed. Safe to retry regardless of method.
      raise Sdp::Unavailable.new("SDP unreachable: #{e.message}", http_status: nil)
    rescue Errno::ECONNRESET, EOFError, Errno::EPIPE, Net::WriteTimeout => e
      # The socket was live (reset/EOF/broken-pipe/write-timeout). For a GET
      # this is still safe to retry. For a POST the reset can land AFTER the
      # body was delivered and processed — outcome unknown — so it must map to
      # Timeout (reconcile), not the retryable Unavailable.
      if idempotent
        raise Sdp::Unavailable.new("SDP unreachable: #{e.message}", http_status: nil)
      else
        raise Sdp::Timeout.new("SDP write failed mid-flight, outcome unknown: #{e.message}", http_status: nil)
      end
    end

    def build_uri(path, query)
      uri = URI.parse("#{@base_url}#{path}")
      if query
        compacted = query.compact
        uri.query = URI.encode_www_form(compacted) unless compacted.empty?
      end
      uri
    end

    def handle(response, path)
      status = response.code.to_i
      body = parse_body(response.body)

      # HTTP 202 is SDP's "accepted, awaiting signatures" response. It is in
      # the 2xx range but carries the ERROR envelope, so it must be handled
      # before the success branch or it silently parses as a success.
      raise_typed_error(status, body, path) if status == 202

      if (200..299).cover?(status)
        # parse_body returns nil both for an empty body (204, fine) and for a
        # non-empty body that failed to parse. The latter must not slip through
        # as Response(data: nil) — that NoMethodErrors later in resource
        # readers. Distinguish the two by the raw body and raise a typed error
        # for the truncated/unparseable case.
        if body.nil? && !response.body.to_s.empty?
          raise Sdp::Unavailable.new("malformed response from SDP (unparseable body)", http_status: status)
        end

        data = body.is_a?(Hash) && body.key?("data") ? body["data"] : body
        meta = body.is_a?(Hash) ? body["meta"] : nil
        return Response.new(data: symbolize(data), meta: symbolize(meta))
      end

      raise_typed_error(status, body, path)
    end

    def parse_body(raw)
      return nil if raw.nil? || raw.empty?
      JSON.parse(raw)
    rescue JSON::ParserError
      nil
    end

    def raise_typed_error(status, body, path)
      error = body.is_a?(Hash) ? body["error"] : nil
      code = error.is_a?(Hash) ? error["code"] : nil
      message = (error.is_a?(Hash) && error["message"]) || "SDP request failed (HTTP #{status})"
      details =
        if error.is_a?(Hash)
          symbolize(error["details"])
        elsif body.is_a?(Hash) && body.key?("data")
          # A 202 (or similar) can carry a data envelope rather than an error
          # object (e.g. a pending transfer's id). Surface that as details so
          # the rescued SigningPending can recover the transferId.
          symbolize(body["data"])
        end
      meta = body.is_a?(Hash) ? symbolize(body["meta"]) : nil

      klass = error_class_for(status, code)
      klass, message = capability_gate(klass, status, code, message, path)
      message = "#{message} #{NOT_FOUND_HINT}" if klass <= Sdp::NotFound
      raise klass.new(message, code: code, http_status: status, details: details, meta: meta)
    end

    # FL-10/FL-11: SDP reports custody/fee-payment capability gates as
    # generic 400/409/502 responses. Discriminators verified against SDP
    # v0.31 (pattern constants documented in errors.rb). The upstream
    # message is preserved and the fix is appended, so logs keep the
    # original evidence.
    def capability_gate(klass, status, code, message, path)
      if status == 400 && path.to_s.end_with?("/v1/wallets") &&
         message.to_s.match?(Sdp::ProviderCapabilityError::PROVISIONING_GATE_PATTERN)
        [ Sdp::ProviderCapabilityError,
          "#{message} — local custody holds a single root wallet; Wallet-per-User requires a " \
          "managed provider (e.g. privy) — set provider: on create_wallet or SDP_CUSTODY_PROVIDER." ]
      elsif status == 409 && path.to_s.end_with?("/v1/wallets/initialize")
        [ Sdp::ProviderCapabilityError,
          "#{message} — custody is already initialized for this organization/project; " \
          "initialize_custody is one-time. Use list_wallets to find the existing root wallet." ]
      elsif status == 502 && code == "SOLANA_RPC_ERROR" &&
            message.to_s.match?(Sdp::TransferExecutionError::NATIVE_ADAPTER_PATTERN)
        [ Sdp::TransferExecutionError,
          "#{message} — SDP's native fee adapter cannot submit transactions; " \
          "run Kora and set FEE_PAYMENT_PROVIDER=kora." ]
      else
        [ klass, message ]
      end
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

    # Shared resource helpers — defined once on the HTTP layer the resource
    # modules mix into, rather than duplicated per module.

    # Percent-encode a caller-supplied id before interpolating it into a path.
    def encode_path_segment(segment)
      URI.encode_uri_component(segment.to_s)
    end

    # Serialize a money amount to a plain decimal string. Integer/String pass
    # through unchanged (Integer#to_s never uses scientific notation); a Float
    # is routed through BigDecimal so a small value like 1e-07 serializes as
    # "0.0000001" rather than "1.0e-07", which SDP rejects. Prefer passing
    # base-unit amounts as strings — Floats are lossy.
    def amount_string(amount)
      return amount.to_s unless amount.is_a?(Float)

      BigDecimal(amount.to_s).to_s("F")
    end
  end
end
