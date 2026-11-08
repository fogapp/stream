# typed: strict
# frozen_string_literal: true

module TmdbSettingSerializer
  extend T::Sig

  # Never the key itself. Whether one is set and how the last test went,
  # even before there's a row to say so.
  sig { params(setting: T.nilable(TmdbSetting)).returns(T::Hash[Symbol, T.untyped]) }
  def self.setting_json(setting)
    return { configured: false, last_tested_at: nil, last_test_ok: nil, last_test_message: nil } if setting.nil?

    { configured: setting.configured?, **ConnectionTestSerializer.tested(setting) }
  end
end
