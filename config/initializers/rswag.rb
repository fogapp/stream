# typed: false
# frozen_string_literal: true

# Serves swagger/v1/openapi.yaml, and a browser for it, at /api-docs
# (PROPOSAL §7.6). The file is generated from spec/requests/openapi.
Rswag::Api.configure do |config|
  config.openapi_root = Rails.root.join("swagger").to_s
end

Rswag::Ui.configure do |config|
  config.openapi_endpoint "/api-docs/v1/openapi.yaml", "Stream API v1"
end
