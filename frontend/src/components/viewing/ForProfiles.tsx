import { useEffect, useState } from "react";
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { Users } from "lucide-react";
import { api } from "@/api/client";
import { keys } from "@/lib/queryKeys";
import { profilesQuery } from "@/lib/queries";
import { useAuth } from "@/hooks/useAuth";
import { Checkbox } from "@/components/ui/Checkbox";
import { Menu } from "@/components/ui/Menu";

/**
 * "For profiles" (PROPOSAL §7.4): tag a title, channel or album for the
 * profiles that need telling — a curated one sees only its tags, and a tag
 * lets a title past a rating ceiling. Admins only.
 */
export function ForProfiles({ item, align = "left" }: { item: { kind: "movie" | "show" | "channel" | "album"; id: string }; align?: "left" | "right" }) {
  const { user } = useAuth();
  const queryClient = useQueryClient();
  const admin = user?.role === "admin";
  const profiles = useQuery({ ...profilesQuery(), enabled: admin });
  const tags = useQuery({
    queryKey: keys.profileTags.item(item.kind, item.id),
    queryFn: ({ signal }) => api.get<{ profile_ids: string[] }>(`/profile_tags?taggable_type=${item.kind}&taggable_id=${item.id}`, { signal }),
    enabled: admin,
  });
  const toggle = useMutation({
    mutationFn: ({ profileId, tagged }: { profileId: string; tagged: boolean }) =>
      api.put<{ profile_ids: string[] }>("/profile_tags", { profile_id: profileId, taggable_type: item.kind, taggable_id: item.id, tagged }),
    onSuccess: (data) => queryClient.setQueryData(keys.profileTags.item(item.kind, item.id), data),
  });
  // Ticked at once; the server's answer follows.
  const [shown, setShown] = useState<string[] | null>(null);
  useEffect(() => setShown(null), [tags.data]);
  const limited = (profiles.data ?? []).filter((profile) => profile.curated || profile.max_rating_age !== null || profile.kind === "kid");
  if (!admin || limited.length === 0) return null;
  const tagged = new Set(shown ?? tags.data?.profile_ids ?? []);

  return (
    <Menu label="For profiles" align={align} icon={<Users className="h-4 w-4" aria-hidden />} className="self-center">
      <div className="space-y-2">
        {limited.map((profile) => (
          <Checkbox
            key={profile.id}
            label={profile.name}
            checked={tagged.has(profile.id)}
            onChange={(on) => {
              const next = new Set(tagged);
              if (on) next.add(profile.id);
              else next.delete(profile.id);
              setShown([...next]);
              toggle.mutate({ profileId: profile.id, tagged: on });
            }}
          />
        ))}
      </div>
    </Menu>
  );
}
