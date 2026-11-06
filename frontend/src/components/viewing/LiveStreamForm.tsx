import { useState, type FormEvent } from "react";
import { useQueryClient } from "@tanstack/react-query";
import { api } from "@/api/client";
import { useFormMutation } from "@/hooks/useFormMutation";
import { useTestConnection } from "@/hooks/useTestConnection";
import { describeTracks, kindOfLink, LIVE_STREAM_FEED_LABELS, LIVE_STREAM_KIND_OPTIONS, LIVE_STREAM_RATINGS } from "@/lib/liveStreams";
import { keys } from "@/lib/queryKeys";
import { TestButton } from "@/components/settings/TestButton";
import { TestResultLine } from "@/components/settings/TestResultLine";
import { Card, CardBody, CardHeader } from "@/components/ui/Card";
import { FormError, FormFooter } from "@/components/ui/Form";
import { Input } from "@/components/ui/Input";
import { Select } from "@/components/ui/Select";
import { Textarea } from "@/components/ui/Textarea";
import { Toggle } from "@/components/ui/Toggle";
import {
  LIVE_STREAM_FEEDS,
  LIVE_STREAM_KINDS,
  type Library,
  type LiveStream,
  type LiveStreamFeed,
  type LiveStreamKind,
  type LiveStreamTestResult,
} from "@/types";

/**
 * Add or edit a live stream (PROPOSAL §7.8): a camera, a web stream, a YouTube
 * live stream or an MLB.tv game, by address (Baseball plays every game without
 * one). An address is kept only once Stream has read a picture from it, and
 * never shown again — `source` stands in for it. Starts from the server's values and does not re-sync on refetch. */
export function LiveStreamForm({
  stream,
  library,
  libraries,
  onDone,
}: {
  stream?: LiveStream;
  /** The library whose page it's on: a new stream goes there. */
  library: Library;
  /** Every live library, to move a stream between them. */
  libraries: Library[];
  onDone: () => void;
}) {
  const queryClient = useQueryClient();
  const [name, setName] = useState(stream?.name ?? "");
  const [libraryId, setLibraryId] = useState(stream?.library_id ?? library.id);
  const [kind, setKind] = useState<LiveStreamKind>(stream?.kind ?? "camera");
  const [url, setUrl] = useState("");
  const [feed, setFeed] = useState<LiveStreamFeed>(stream?.feed ?? "home");
  const [trust, setTrust] = useState(stream?.trust_certificate ?? false);
  // A new camera starts kept connected; a web stream doesn't.
  const [keep, setKeep] = useState<boolean | null>(stream?.keep_connected ?? null);
  const keepConnected = keep ?? kind === "camera";
  const option = LIVE_STREAM_KIND_OPTIONS[kind];
  const [rating, setRating] = useState(stream?.content_rating ?? "");
  const [description, setDescription] = useState(stream?.description ?? "");
  const body = () => ({
    ...(stream ? { id: stream.id } : {}),
    live_stream: {
      name,
      library_id: libraryId,
      kind,
      feed: kind === "mlb" ? feed : null,
      url,
      trust_certificate: option.certificate && trust,
      keep_connected: keepConnected,
      content_rating: rating || null,
      description: description.trim() || null,
    },
  });
  const test = useTestConnection<LiveStreamTestResult>("/live_streams/test", keys.liveStreams.all, body);
  const save = useFormMutation({
    mutationFn: () => {
      const { live_stream } = body();
      return stream
        ? api.patch<LiveStream>(`/live_streams/${stream.id}`, { live_stream })
        : api.post<LiveStream>("/live_streams", { live_stream });
    },
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: keys.liveStreams.all });
      onDone();
    },
    fallback: "Could not save the stream",
  });

  function onSubmit(event: FormEvent) {
    event.preventDefault();
    save.mutate();
  }

  return (
    <Card>
      <CardHeader title={stream ? `Edit ${stream.name}` : "Add a live stream"} />
      <CardBody>
        <form onSubmit={onSubmit} className="max-w-xl space-y-4">
          <Input label="Name" value={name} onChange={(event) => setName(event.target.value)} placeholder="Front door" required />
          {libraries.length > 1 ? (
            <Select label="Library" value={libraryId} onChange={(event) => setLibraryId(event.target.value)}>
              {libraries.map((library) => (
                <option key={library.id} value={library.id}>
                  {library.name}
                </option>
              ))}
            </Select>
          ) : null}
          <Select
            label="Kind"
            value={kind}
            onChange={(event) => setKind(event.target.value as LiveStreamKind)}
            hint={option.hint}
          >
            {LIVE_STREAM_KINDS.map((value) => (
              <option key={value} value={value}>
                {LIVE_STREAM_KIND_OPTIONS[value].label}
              </option>
            ))}
          </Select>
          <Input
            label={stream ? "Replace the address" : "Address"}
            type={option.secret ? "password" : "text"}
            autoComplete="off"
            className="font-mono"
            value={url}
            onChange={(event) => {
              setUrl(event.target.value);
              // A YouTube or MLB.tv link plays only as its own kind.
              const linked = kindOfLink(event.target.value);
              if (linked) setKind(linked);
            }}
            placeholder={stream ? `Saved (${stream.source}) — enter a new one to replace it` : option.placeholder}
            hint={
              option.secret
                ? "Kept encrypted and never shown again: it often carries the camera's password or token."
                : "Stream finds the stream's playlists from the link each time it connects."
            }
            required={!stream}
          />
          {kind === "mlb" ? (
            <Select
              label="Broadcast"
              value={feed}
              onChange={(event) => setFeed(event.target.value as LiveStreamFeed)}
              hint="Which team's TV broadcast to play. When the game has only one, as national broadcasts do, that one plays."
            >
              {LIVE_STREAM_FEEDS.map((value) => (
                <option key={value} value={value}>
                  {LIVE_STREAM_FEED_LABELS[value]}
                </option>
              ))}
            </Select>
          ) : null}
          {option.certificate ? (
            <Toggle
              label="Trust its certificate"
              hint="For an rtsps:// or https:// address with its own certificate, as cameras have. Leave off for a site with a real one."
              checked={trust}
              onChange={setTrust}
            />
          ) : null}
          <Toggle
            label="Keep connected"
            hint="Stream holds one connection to it all the time, so pressing play shows the picture at once instead of waiting for the camera's next keyframe."
            checked={keepConnected}
            onChange={setKeep}
          />
          <Select label="Rating" value={rating} onChange={(event) => setRating(event.target.value)} hint="Profiles with a rating limit see it only if it's within theirs.">
            {LIVE_STREAM_RATINGS.map((value) => (
              <option key={value} value={value}>
                {value || "Unrated"}
              </option>
            ))}
          </Select>
          <Textarea label="Description" value={description} onChange={(event) => setDescription(event.target.value)} rows={2} />
          <div className="flex flex-wrap items-center gap-3">
            <TestButton connection={test} disabled={!stream && !url.trim()} label="Test address" />
            <TestResultLine ok={test.result?.ok ?? null} message={test.result?.message ?? null} />
          </div>
          {test.result?.tracks?.length ? <p className="text-sm text-muted">{describeTracks(test.result.tracks)}</p> : null}
          <FormError message={save.errorMessage} />
          <FormFooter label={stream ? "Save" : "Add stream"} pending={save.isPending} onCancel={onDone} />
        </form>
      </CardBody>
    </Card>
  );
}
