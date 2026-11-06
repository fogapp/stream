/** Rating ceilings by age, as profiles and Grid channels choose them (the backend's rating_age). */
export const RATING_CEILINGS: { value: string; label: string }[] = [
  { value: "", label: "No limit" },
  { value: "0", label: "Little kids — G, TV-Y, U" },
  { value: "7", label: "Older kids — TV-Y7" },
  { value: "10", label: "Family — PG, TV-PG" },
  { value: "13", label: "Teens — PG-13, 12A" },
  { value: "16", label: "Older teens — TV-14, 15" },
];
