# typed: strict
# frozen_string_literal: true

module TmdbSettingSerializer
  extend T::Sig

  # Never the key itself.
  sig { params(setting: TmdbSetting).returns(T::Hash[Symbol, T.untyped]) }
  def self.setting_json(setting)
    {
      configured: setting.configured?,
      last_tested_at: setting.last_tested_at, last_test_ok: setting.last_test_ok,
      last_test_message: setting.last_test_message
    }
  end
end
