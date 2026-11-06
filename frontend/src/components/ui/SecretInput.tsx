import type { ComponentProps } from "react";
import { Input } from "@/components/ui/Input";

/**
 * A key or a password: write-only, so a saved one shows as saved rather than
 * as itself, and an empty field means keep it.
 */
export function SecretInput({ saved, placeholder, ...props }: Omit<ComponentProps<typeof Input>, "type" | "autoComplete"> & { saved: boolean }) {
  return <Input type="password" autoComplete="off" placeholder={saved ? "Saved — enter a new one to replace it" : placeholder} {...props} />;
}
