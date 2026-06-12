# frozen_string_literal: true

module Sdp
  # Lazy enumeration over SDP list endpoints.
  #
  # Two modes, keyed on whether the caller pinned a page:
  #
  # - No :page in the query — auto-paginate. The enumerator fetches the first
  #   page on first consumption and follows meta.hasMore, requesting the next
  #   page only when iteration runs past the rows already fetched (so
  #   `enum.take(3)` against a 20-row first page performs exactly one
  #   request). Filters are re-sent on every page request.
  # - Explicit :page — single page. The enumerator yields exactly that page's
  #   rows and never fetches another, even when meta.hasMore is true.
  #
  # :pageSize is clamped client-side to MAX_PAGE_SIZE — SDP rejects larger
  # values, and a clamped request is more useful than a guaranteed 400.
  #
  # Non-paginated list endpoints (GET /v1/wallets at v0.28) flow through the
  # same helper: their meta carries no hasMore, so enumeration stops after a
  # single fetch — and they pick up auto-pagination for free if SDP paginates
  # them in a later version.
  module Pagination
    MAX_PAGE_SIZE = 100 # SDP's pageSize ceiling (v0.28)

    # client — anything exposing #get(path, query:) → Client::Response
    # query  — wire-shaped (camelCase keys), nils allowed (compacted here)
    # mapper — called once per page with the Response; returns that page's rows
    def self.enumerate(client, path, query = {}, &mapper)
      query = query.compact
      query[:pageSize] = [ query[:pageSize].to_i, MAX_PAGE_SIZE ].min if query.key?(:pageSize)
      single_page = query.key?(:page)

      Enumerator.new do |yielder|
        page = query[:page]
        loop do
          request_query = page ? query.merge(page: page) : query
          response = client.get(path, query: request_query)
          rows = mapper.call(response)
          rows.each { |row| yielder << row }

          break if single_page

          meta = response.meta || {}
          # An empty page also stops: hasMore with zero rows would loop forever.
          break if rows.empty? || !meta[:has_more]

          page = (meta[:page] || page || 1) + 1
        end
      end
    end
  end
end
