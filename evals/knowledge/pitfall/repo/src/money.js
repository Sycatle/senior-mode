const locale = globalThis.__locale ?? "en-US";

export const euros = (cents) => (cents / 100).toLocaleString(locale, { minimumFractionDigits: 2 });
