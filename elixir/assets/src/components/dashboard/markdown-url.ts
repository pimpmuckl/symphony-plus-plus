export function safeMarkdownUrl(url: string) {
  const value = url.trim();
  if (!value || value.startsWith("//")) return "";
  if (hasUnsafeUrlControl(value) || /%(?:0[0-9a-f]|1[0-9a-f]|7f)/i.test(value)) return "";

  const protocolMatch = value.match(/^[A-Za-z][A-Za-z\d+.-]*:/);
  if (!protocolMatch) return value;

  return ["http:", "https:", "mailto:"].includes(protocolMatch[0].toLowerCase()) ? value : "";
}

function hasUnsafeUrlControl(value: string) {
  return Array.from(value).some((char) => {
    const code = char.charCodeAt(0);
    return code <= 32 || code === 127;
  });
}
