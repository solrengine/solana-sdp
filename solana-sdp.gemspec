require_relative "lib/sdp/version"

Gem::Specification.new do |spec|
  spec.name = "solana-sdp"
  spec.version = Sdp::VERSION
  spec.authors = [ "Jose Ferrer" ]
  spec.email = [ "estoy@moviendo.me" ]

  spec.summary = "Ruby client for the Solana Developer Platform (SDP)"
  spec.description = "Zero-dependency Net::HTTP client for SDP's wallets and payments API: typed errors, envelope unwrapping, and a safe retry posture."
  spec.homepage = "https://github.com/solrengine/solana-sdp"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.2.0"

  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = spec.homepage

  spec.files = Dir["lib/**/*", "LICENSE.txt", "README.md"]
  spec.require_paths = [ "lib" ]
end
