# frozen_string_literal: true

require "minitest/autorun"
require "webmock/minitest"
require "solana-sdp"

# Stub by default; nothing in this suite should hit the network.
WebMock.disable_net_connect!
