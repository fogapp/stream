import { Link } from "react-router-dom";
import { UserRound } from "lucide-react";
import { ArtworkImage } from "@/components/viewing/ArtworkImage";
import { Row } from "@/components/viewing/Row";
import type { CastMember } from "@/types";

export function CastRow({ cast }: { cast: CastMember[] }) {
  const actors = cast.filter((member) => member.role === "cast");
  if (actors.length === 0) return null;
  return (
    <Row title="Cast">
      {actors.map((member) => (
        <Link key={`${member.person_id}-${member.character ?? ""}`} to={`/person/${member.person_id}`} className="group w-24 shrink-0 snap-start sm:w-28">
          <ArtworkImage
            image={member.image}
            sizes="7rem"
            className="aspect-square rounded-full ring-1 ring-border transition group-hover:ring-2 group-hover:ring-primary"
            fallback={<UserRound className="h-8 w-8 text-muted" aria-hidden />}
          />
          <p className="mt-2 truncate text-center text-sm text-foreground">{member.name}</p>
          {member.character ? <p className="truncate text-center text-xs text-muted">{member.character}</p> : null}
        </Link>
      ))}
    </Row>
  );
}
