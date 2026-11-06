# typed: strict
# frozen_string_literal: true

# Settings › Integrations for the services Stream calls with a secret
# (CLAUDE.md, configuration belongs in the UI): what's set and how the last
# test went — never the key or password, only whether one is set.
module IntegrationSettingSerializer
  extend T::Sig

  sig { params(setting: T.nilable(WhisperSetting)).returns(T::Hash[Symbol, T.untyped]) }
  def self.whisper_json(setting)
    return { configured: false } if setting.nil?

    {
      configured: true, url: setting.url, api_kind: setting.api_kind_enum.serialize, model: setting.model, enabled: setting.enabled,
      api_key_set: setting.api_key.present?, **tested(setting)
    }
  end

  sig { params(setting: T.nilable(OpenSubtitlesSetting)).returns(T::Hash[Symbol, T.untyped]) }
  def self.open_subtitles_json(setting)
    return { configured: false } if setting.nil?

    {
      configured: true, username: setting.username, languages: setting.languages, enabled: setting.enabled,
      remaining_downloads: setting.remaining_downloads, resets_at: setting.resets_at, **tested(setting)
    }
  end

  sig { params(setting: T.nilable(MlbSetting)).returns(T::Hash[Symbol, T.untyped]) }
  def self.mlb_json(setting)
    return { configured: false } if setting.nil?

    { configured: true, username: setting.username, **tested(setting) }
  end

  sig { params(setting: T.nilable(NbaSetting)).returns(T::Hash[Symbol, T.untyped]) }
  def self.nba_json(setting)
    return { configured: false } if setting.nil?

    { configured: true, **tested(setting) }
  end

  sig { params(setting: T.nilable(ImmichSetting)).returns(T::Hash[Symbol, T.untyped]) }
  def self.immich_json(setting)
    return { configured: false } if setting.nil?

    {
      configured: true, url: setting.url, immich_path_prefix: setting.immich_path_prefix, local_path_prefix: setting.local_path_prefix,
      enabled: setting.enabled, **tested(setting), last_synced_at: setting.last_synced_at, last_sync_error: setting.last_sync_error,
      last_sync_counts: setting.last_sync_counts
    }
  end

  sig { params(setting: T.any(WhisperSetting, OpenSubtitlesSetting, ImmichSetting, MlbSetting, NbaSetting)).returns(T::Hash[Symbol, T.untyped]) }
  def self.tested(setting)
    { last_test_ok: setting.last_test_ok, last_test_message: setting.last_test_message, last_tested_at: setting.last_tested_at }
  end
  private_class_method :tested
end
