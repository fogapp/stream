# frozen_string_literal: true

# What a Dolby Vision base layer is besides (1 HDR10, 4 HLG, 2 SDR, 6
# Blu-ray HDR10), kept on the stream's row as Media::Probe.normalize reads
# it, so Playback::Decision decides from rows alone (media invariant 4)
# rather than reading the stored probe at play time. The rows probed
# before codec_tag was kept get it from the stored probe too, which is what
# Decision fell back to.
class AddDolbyVisionCompatibilityToMediaStreams < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  class FileRow < ActiveRecord::Base
    self.table_name = "media_files"
  end

  class StreamRow < ActiveRecord::Base
    self.table_name = "media_streams"
  end

  def up
    add_column :media_streams, :dolby_vision_compatibility, :integer, if_not_exists: true
    backfill_codec_tags
    backfill_dolby_vision
  end

  def down
    remove_column :media_streams, :dolby_vision_compatibility, if_exists: true
  end

  # As Media::Probe.normalize keeps it: the stream's codec_tag_string, when
  # it has one.
  def backfill_codec_tags
    execute(<<~SQL.squish)
      UPDATE media_streams SET codec_tag = NULLIF(probed.value->>'codec_tag_string', '')
      FROM media_files, jsonb_array_elements(CASE WHEN jsonb_typeof(media_files.probe->'streams') = 'array'
        THEN media_files.probe->'streams' ELSE '[]'::jsonb END) AS probed(value)
      WHERE media_streams.media_file_id = media_files.id AND media_streams.codec_tag IS NULL
        AND probed.value->>'index' = media_streams.index::text AND NULLIF(probed.value->>'codec_tag_string', '') IS NOT NULL
    SQL
  end

  # The same Ruby as Media::Probe.normalize (and Decision before it), for
  # every file whose probe saw Dolby Vision.
  def backfill_dolby_vision
    FileRow.where("probe::text LIKE ?", "%DOVI%").select(:id, :probe).find_each do |file|
      Array(file.probe.is_a?(Hash) ? file.probe["streams"] : nil).each do |stream|
        dovi = Array(stream["side_data_list"]).find { |side| side["side_data_type"].to_s.include?("DOVI") }
        next if dovi.nil?

        compatibility = Integer(dovi["dv_bl_signal_compatibility_id"].to_s, exception: false)
        next if compatibility.nil?

        StreamRow.where(media_file_id: file.id, index: stream["index"]).update_all(dolby_vision_compatibility: compatibility)
      end
    end
  end
end
