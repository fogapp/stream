# frozen_string_literal: true

# The new stream facts from the probe each file already keeps, in SQL: no
# file is read again.
class BackfillProbeFacts < ActiveRecord::Migration[8.1]
  def up
    execute <<~SQL
      UPDATE media_streams ms SET
        start_time = NULLIF(s->>'start_time', '')::float,
        field_order = NULLIF(s->>'field_order', ''),
        sample_aspect_ratio = NULLIF(s->>'sample_aspect_ratio', ''),
        rotation = COALESCE(
          (SELECT round((sd->>'rotation')::float)::int FROM jsonb_array_elements(COALESCE(s->'side_data_list', '[]'::jsonb)) sd
            WHERE sd ? 'rotation' LIMIT 1),
          NULLIF(s->'tags'->>'rotate', '')::int),
        sample_rate = NULLIF(s->>'sample_rate', '')::int,
        codec_tag = NULLIF(s->>'codec_tag_string', ''),
        chroma = CASE
          WHEN s->>'pix_fmt' IS NULL THEN NULL
          WHEN s->>'pix_fmt' LIKE '%444%' OR s->>'pix_fmt' LIKE 'gbr%' OR s->>'pix_fmt' LIKE 'rgb%' OR s->>'pix_fmt' LIKE 'bgr%' THEN '444'
          WHEN s->>'pix_fmt' LIKE '%422%' OR s->>'pix_fmt' IN ('yuyv422', 'uyvy422', 'nv16', 'p210le') THEN '422'
          WHEN s->>'pix_fmt' LIKE '%411%' THEN '411'
          WHEN s->>'pix_fmt' LIKE 'gray%' THEN '400'
          ELSE '420' END,
        refs = NULLIF(s->>'refs', '')::int,
        has_b_frames = NULLIF(s->>'has_b_frames', '')::int,
        comment = COALESCE((s->'disposition'->>'comment')::int = 1, false),
        hearing_impaired = COALESCE((s->'disposition'->>'hearing_impaired')::int = 1, false),
        visual_impaired = COALESCE((s->'disposition'->>'visual_impaired')::int = 1, false)
      FROM media_files f, jsonb_array_elements(COALESCE(f.probe->'streams', '[]'::jsonb)) s
      WHERE ms.media_file_id = f.id AND (s->>'index')::int = ms.index
    SQL
    execute <<~SQL
      UPDATE media_files SET start_time = NULLIF(probe->'format'->>'start_time', '')::float
      WHERE probe ? 'format'
    SQL
  end

  def down; end
end
