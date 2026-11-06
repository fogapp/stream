import type { ReactNode } from "react";
import { FormError, FormFooter } from "@/components/ui/Form";

/**
 * A form that saves through one mutation (useFormMutation): its fields, its
 * failure said beside them, and its submit button.
 */
export function MutationForm({
  mutation,
  label,
  pendingLabel,
  disabled,
  onCancel,
  className = "max-w-xl space-y-4",
  children,
}: {
  mutation: { mutate: () => void; isPending: boolean; errorMessage: string | null };
  label: string;
  pendingLabel?: string;
  disabled?: boolean;
  onCancel?: () => void;
  className?: string;
  children: ReactNode;
}) {
  return (
    <form
      className={className}
      onSubmit={(event) => {
        event.preventDefault();
        mutation.mutate();
      }}
    >
      {children}
      <FormError message={mutation.errorMessage} />
      <FormFooter label={label} pendingLabel={pendingLabel} pending={mutation.isPending} disabled={disabled} onCancel={onCancel} />
    </form>
  );
}
