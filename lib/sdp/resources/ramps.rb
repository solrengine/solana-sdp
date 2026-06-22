# frozen_string_literal: true

module Sdp
  # Currency discovery for a ramp direction: which fiat/crypto SDP can move
  # between and which providers serve each pair. Passed through close to how SDP
  # reports it — pairs is an array of { source, dest, providers } hashes.
  RampCurrencies = Struct.new(:sources, :destinations, :pairs, :support_hash, keyword_init: true) do
    def self.from_hash(hash)
      hash ||= {}
      currencies = hash[:currencies] || {}
      new(
        sources: currencies[:sources] || [],
        destinations: currencies[:destinations] || [],
        pairs: hash[:pairs] || [],
        support_hash: hash[:support_hash]
      )
    end
  end

  # A ramp quote: indicative pricing plus a hosted checkout URL for an on-ramp.
  # SDP omits optional fields, so each member is nil when absent. The *_currency
  # members are passed through as { code, decimals, name, symbol } hashes;
  # amounts are numbers as SDP sends them.
  RampQuote = Struct.new(:id, :provider, :status, :delivery_mode, :hosted_url, :payment_instructions,
                         :exchange_rate, :total_sending_amount, :sending_currency,
                         :total_receiving_amount, :receiving_currency, :fees_included, :fee_currency,
                         :expires_at, keyword_init: true) do
    def self.from_hash(hash)
      hash ||= {}
      new(
        id: hash[:id],
        provider: hash[:provider],
        status: hash[:status],
        delivery_mode: hash[:delivery_mode],
        hosted_url: hash[:hosted_url],
        payment_instructions: hash[:payment_instructions],
        exchange_rate: hash[:exchange_rate],
        total_sending_amount: hash[:total_sending_amount],
        sending_currency: hash[:sending_currency],
        total_receiving_amount: hash[:total_receiving_amount],
        receiving_currency: hash[:receiving_currency],
        fees_included: hash[:fees_included],
        fee_currency: hash[:fee_currency],
        expires_at: hash[:expires_at]
      )
    end
  end

  # The result of executing a ramp: SDP's ramp record with the redirect/checkout
  # URL and a provider reference for reconciliation.
  RampExecution = Struct.new(:id, :provider, :status, :redirect_url, :payment_instructions, :reference,
                             keyword_init: true) do
    def self.from_hash(hash)
      hash ||= {}
      new(
        id: hash[:id],
        provider: hash[:provider],
        status: hash[:status],
        redirect_url: hash[:redirect_url],
        payment_instructions: hash[:payment_instructions],
        reference: hash[:reference]
      )
    end
  end

  module Resources
    # Fiat on/off-ramps (SDP payments/ramps).
    #
    # SANDBOX-ONLY at v0.2: wired against SDP's ramp surface and the sandbox
    # simulate hook, NOT verified against live fiat rails. The execute calls are
    # POSTs and follow the same never-retry-on-write posture as transfers (a ramp
    # moves money). #simulate_ramp drives a sandbox ramp to a terminal state.
    #
    # The execute/quote requests carry a large provider KYC/compliance payload
    # (SDP's bvnkCompliance). Rather than model that nested blob, the core fields
    # are keyword args and the compliance object is passed through via compliance:.
    module Ramps
      # GET /v1/payments/ramps/onramp/currency → Sdp::RampCurrencies
      # Filters (camelCased on the wire): source:, dest:, provider:.
      def onramp_currencies(source: nil, dest: nil, provider: nil)
        RampCurrencies.from_hash(ramp_currencies("onramp", source, dest, provider))
      end

      # GET /v1/payments/ramps/offramp/currency → Sdp::RampCurrencies
      def offramp_currencies(source: nil, dest: nil, provider: nil)
        RampCurrencies.from_hash(ramp_currencies("offramp", source, dest, provider))
      end

      # POST /v1/payments/ramps/onramp/quote → Sdp::RampQuote.
      # Indicative pricing for a fiat→crypto on-ramp. Never retried (write).
      def onramp_quote(provider:, counterparty_id:, destination_wallet:, crypto_token:,
                       fiat_currency:, fiat_amount:, redirect_url: nil, collected_data: nil)
        payload = {
          provider: provider, counterpartyId: counterparty_id, destinationWallet: destination_wallet,
          cryptoToken: crypto_token, fiatCurrency: fiat_currency, fiatAmount: fiat_amount.to_s,
          redirectUrl: redirect_url, collectedData: collected_data
        }.compact
        RampQuote.from_hash(ramp_record(post("/v1/payments/ramps/onramp/quote", payload).data, :quote))
      end

      # POST /v1/payments/ramps/onramp/execute → Sdp::RampExecution.
      # Custodial money movement; never retried. compliance: maps to SDP's
      # bvnkCompliance payload.
      def onramp_execute(provider:, counterparty_id:, destination_wallet:, crypto_token:,
                         fiat_currency:, fiat_amount:, kyc_reference: nil, redirect_url: nil, compliance: nil)
        payload = {
          provider: provider, counterpartyId: counterparty_id, destinationWallet: destination_wallet,
          cryptoToken: crypto_token, fiatCurrency: fiat_currency, fiatAmount: fiat_amount.to_s,
          kycReference: kyc_reference, redirectUrl: redirect_url, bvnkCompliance: compliance
        }.compact
        RampExecution.from_hash(ramp_record(post("/v1/payments/ramps/onramp/execute", payload).data, :ramp))
      end

      # POST /v1/payments/ramps/offramp/execute → Sdp::RampExecution.
      # Custodial money movement (crypto→fiat); never retried.
      def offramp_execute(provider:, counterparty_id:, source_wallet:, crypto_token:,
                          fiat_currency:, crypto_amount:, kyc_reference: nil, redirect_url: nil, compliance: nil)
        payload = {
          provider: provider, counterpartyId: counterparty_id, sourceWallet: source_wallet,
          cryptoToken: crypto_token, fiatCurrency: fiat_currency, cryptoAmount: crypto_amount.to_s,
          kycReference: kyc_reference, redirectUrl: redirect_url, bvnkCompliance: compliance
        }.compact
        RampExecution.from_hash(ramp_record(post("/v1/payments/ramps/offramp/execute", payload).data, :ramp))
      end

      # POST /v1/payments/ramps/sandbox/simulate → the simulated transaction (Hash passthrough, nil if absent).
      # Sandbox-only test hook: advances a sandbox ramp to a terminal state.
      # payload is forwarded as-is (SDP leaves the body provider-shaped).
      def simulate_ramp(payload = {})
        data = post("/v1/payments/ramps/sandbox/simulate", payload).data
        data.is_a?(Hash) ? data[:transaction] : nil
      end

      private

      def ramp_currencies(direction, source, dest, provider)
        query = { source: source, dest: dest, provider: provider }.compact
        get("/v1/payments/ramps/#{direction}/currency", query: query).data
      end

      # quote/execute wrap the record in data.quote / data.ramp; stay tolerant of
      # a bare record (or empty body → {}) so the struct degrades to all-nil.
      def ramp_record(data, key)
        data.is_a?(Hash) ? (data[key] || data) : {}
      end
    end
  end
end
