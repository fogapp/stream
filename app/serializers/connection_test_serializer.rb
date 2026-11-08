# typed: strict
# frozen_string_literal: true

# How a connection's last Settings test went (ConnectionTested), as every
# integration's card shows it under its Test button.
module ConnectionTestSerializer
  extend T::Sig

  Tested = T.type_alias do
    T.any(WhisperSetting, OpenSubtitlesSetting, ImmichSetting, MlbSetting, NbaSetting, TmdbSetting, TraktSetting, PlexConnection)
  end

  sig { params(setting: Tested).returns(T::Hash[Symbol, T.untyped]) }
  def self.tested(setting)
    { last_tested_at: setting.last_tested_at, last_test_ok: setting.last_test_ok, last_test_message: setting.last_test_message }
  end
end
