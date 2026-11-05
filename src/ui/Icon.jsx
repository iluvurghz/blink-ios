const P = {
  play: <path d="M8 5.6v12.8c0 .8.9 1.3 1.6.8l9.6-6.4c.6-.4.6-1.2 0-1.6L9.6 4.8C8.9 4.3 8 4.8 8 5.6Z" fill="currentColor" stroke="none" />,
  pause: (
    <g fill="currentColor" stroke="none">
      <rect x="6.5" y="5" width="4" height="14" rx="1.4" />
      <rect x="13.5" y="5" width="4" height="14" rx="1.4" />
    </g>
  ),
  next: (
    <g>
      <path d="M5 6.2v11.6c0 .7.8 1.1 1.4.7l8.2-5.8c.5-.4.5-1.1 0-1.4L6.4 5.5C5.8 5.1 5 5.5 5 6.2Z" fill="currentColor" stroke="none" />
      <path d="M18.5 5.5v13" />
    </g>
  ),
  prev: (
    <g>
      <path d="M19 6.2v11.6c0 .7-.8 1.1-1.4.7l-8.2-5.8c-.5-.4-.5-1.1 0-1.4l8.2-5.8c.6-.4 1.4 0 1.4.7Z" fill="currentColor" stroke="none" />
      <path d="M5.5 5.5v13" />
    </g>
  ),
  shuffle: <path d="M3.5 7h3.2c1.4 0 2.6.7 3.4 1.8l3.8 6.4c.8 1.1 2 1.8 3.4 1.8h3.2M3.5 17h3.2c1.4 0 2.6-.7 3.4-1.8M13.9 8.8c.8-1.1 2-1.8 3.4-1.8h3.2M18 4.5 20.5 7 18 9.5M18 14.5l2.5 2.5-2.5 2.5" />,
  repeat: <path d="M4 11V9.5A3.5 3.5 0 0 1 7.5 6H19m0 0-2.5-2.5M19 6l-2.5 2.5M20 13v1.5a3.5 3.5 0 0 1-3.5 3.5H5m0 0 2.5 2.5M5 18l2.5-2.5" />,
  repeatOne: (
    <g>
      <path d="M4 11V9.5A3.5 3.5 0 0 1 7.5 6H19m0 0-2.5-2.5M19 6l-2.5 2.5M20 13v1.5a3.5 3.5 0 0 1-3.5 3.5H5m0 0 2.5 2.5M5 18l2.5-2.5" />
      <path d="M11.3 10.6 12.6 10v4.4" />
    </g>
  ),
  heart: <path d="M12 19.5s-7.5-4.4-7.5-10A4.2 4.2 0 0 1 12 6.9a4.2 4.2 0 0 1 7.5 2.6c0 5.6-7.5 10-7.5 10Z" />,
  heartFill: <path d="M12 19.5s-7.5-4.4-7.5-10A4.2 4.2 0 0 1 12 6.9a4.2 4.2 0 0 1 7.5 2.6c0 5.6-7.5 10-7.5 10Z" fill="currentColor" />,
  search: (
    <g>
      <circle cx="11" cy="11" r="6.5" />
      <path d="m16 16 4 4" />
    </g>
  ),
  lyrics: <path d="M5 7h14M5 12h9M5 17h11" />,
  clip: (
    <g>
      <rect x="3.5" y="5.5" width="17" height="13" rx="3.5" />
      <path d="M10.5 9.6v4.8l4-2.4-4-2.4Z" fill="currentColor" />
    </g>
  ),
  queue: <path d="M4 6.5h11M4 11.5h11M4 16.5h6M17.5 13v6.5M14.5 16.2l3-3.2 3 3.2" />,
  volume: <path d="M4.5 9.5v5h3.2l4.3 3.8V5.7L7.7 9.5H4.5ZM15.5 9a4 4 0 0 1 0 6M18 6.5a7.5 7.5 0 0 1 0 11" />,
  mute: <path d="M4.5 9.5v5h3.2l4.3 3.8V5.7L7.7 9.5H4.5ZM16 9.5l5 5M21 9.5l-5 5" />,
  plus: <path d="M12 5v14M5 12h14" />,
  close: <path d="m6 6 12 12M18 6 6 18" />,
  back: <path d="M14.5 5.5 8 12l6.5 6.5" />,
  down: <path d="m5.5 9 6.5 6.5L18.5 9" />,
  more: (
    <g fill="currentColor" stroke="none">
      <circle cx="5.5" cy="12" r="1.6" />
      <circle cx="12" cy="12" r="1.6" />
      <circle cx="18.5" cy="12" r="1.6" />
    </g>
  ),
  min: <path d="M6 12h12" />,
  max: <rect x="6" y="6" width="12" height="12" rx="2" />,
  restore: <path d="M8.5 8.5V6.8c0-.7.6-1.3 1.3-1.3h7.4c.7 0 1.3.6 1.3 1.3v7.4c0 .7-.6 1.3-1.3 1.3h-1.7M5.5 9.8c0-.7.6-1.3 1.3-1.3h7.4c.7 0 1.3.6 1.3 1.3v7.4c0 .7-.6 1.3-1.3 1.3H6.8c-.7 0-1.3-.6-1.3-1.3V9.8Z" />,
  key: (
    <g>
      <circle cx="8" cy="14.5" r="4" />
      <path d="m11 11.5 8-8M16.5 6l2.5 2.5M14 8.5l2 2" />
    </g>
  ),
  bolt: <path d="M13 3 5 13.5h6L10 21l8-10.5h-6L13 3Z" />,
  settings: (
    <g>
      <path d="M4 7h9M17 7h3M4 17h3M11 17h9" />
      <circle cx="15" cy="7" r="2" />
      <circle cx="9" cy="17" r="2" />
    </g>
  ),
  check: <path d="m5 12.5 4.5 4.5L19 7.5" />,
  download: <path d="M12 4.5v10M7.5 10.5 12 15l4.5-4.5M5.5 19h13" />,
  trash: <path d="M5 7h14M10 4.5h4M7 7l.8 11.2c.1.9.8 1.6 1.7 1.6h5c.9 0 1.6-.7 1.7-1.6L17 7" />,
  disc: (
    <g>
      <circle cx="12" cy="12" r="8.5" />
      <circle cx="12" cy="12" r="2" />
    </g>
  ),
  home: <path d="M4.5 10.5 12 4.5l7.5 6V19a.5.5 0 0 1-.5.5h-4.5v-5h-5v5H5a.5.5 0 0 1-.5-.5v-8.5Z" />,
  library: <path d="M5 4.5v15M9.5 4.5v15M14 5.2l4.6 14.1" />,
  external: <path d="M14 4.5h5.5V10M19.5 4.5 11 13M17 14v4.5a1 1 0 0 1-1 1H6a1 1 0 0 1-1-1V8.5a1 1 0 0 1 1-1h4.5" />,
  edit: <path d="M5 19h3.5L18.7 8.8a2.1 2.1 0 0 0-3-3L5.5 16v3Z" />,
  chat: <path d="M5 5.5h14v10H10l-5 4v-14Z" />,
  support: (
    <>
      <path d="M4.5 14v-2a7.5 7.5 0 0 1 15 0v2" />
      <path d="M4.5 13.5h2.8v5.2H5.6a1.1 1.1 0 0 1-1.1-1.1v-4.1Z" />
      <path d="M19.5 13.5h-2.8v5.2h1.7a1.1 1.1 0 0 0 1.1-1.1v-4.1Z" />
      <path d="M18.6 18.7c-.4 1.6-2.4 2.6-5.6 2.6" />
    </>
  ),
  user: (
    <g>
      <circle cx="12" cy="8.5" r="3.8" />
      <path d="M4.8 19.5c1.2-3.4 4-5.2 7.2-5.2s6 1.8 7.2 5.2" />
    </g>
  ),
  together: (
    <g>
      <circle cx="9" cy="8.5" r="3.3" />
      <path d="M3 19c.9-3 3.2-4.6 6-4.6s5.1 1.6 6 4.6" />
      <path d="M15.5 5.6a3.2 3.2 0 0 1 0 6M17.5 14.6c1.7.6 2.9 2 3.5 4.4" />
    </g>
  ),
  wave: <path d="M3 12h2M7 8v8M11 5v14M15 9v6M19 7v10M21 12h0" />,
  eq: <path d="M6 4v6M6 14v6M12 4v2M12 10v10M18 4v10M18 18v2M4 12h4M10 8h4M16 16h4" />,
  share: <path d="M12 4v11M8 8l4-4 4 4M5 13v5.5c0 .8.7 1.5 1.5 1.5h11c.8 0 1.5-.7 1.5-1.5V13" />,
  translate: <path d="M4 6h9M8.5 4v2M6 6c.5 3 2.5 5.5 5 6.5M11 6c-.6 3.4-3 6.3-6 7.5M13 20l4-9 4 9M14.4 17h5.2" />,
  thumbDown: (
    <g>
      <path d="M14.4 3H8.1c-.9 0-1.7.6-1.9 1.5L5 9.7c-.3 1.3.7 2.5 2 2.5h3.2l-.6 3.4c-.2 1.1.4 2.1 1.5 2.4.5.1 1-.1 1.3-.6l2.7-4.6V3Z" />
      <path d="M14.4 3H18c.8 0 1.5.7 1.5 1.5v6c0 .8-.7 1.5-1.5 1.5h-3.6" />
    </g>
  ),
  wifi: (
    <g>
      <path d="M4.5 9.1a11 11 0 0 1 15 0M7.4 12.5a6.6 6.6 0 0 1 9.2 0M10.2 15.8a2.6 2.6 0 0 1 3.6 0" />
      <circle cx="12" cy="18.7" r="1" fill="currentColor" stroke="none" />
    </g>
  ),
  youtube: (
    <g>
      <rect x="3" y="6" width="18" height="12" rx="3.4" />
      <path d="M10.4 9.2v5.6l4.8-2.8-4.8-2.8Z" fill="currentColor" stroke="none" />
    </g>
  ),
  api: <path d="M9 6.5c-2 0-2.3 1.3-2.3 2.7S7.3 12 5.6 12s2.1 2.8 2.1 2.8.3 2.7-.7 2.7M15 6.5c2 0 2.3 1.3 2.3 2.7S16.7 12 18.4 12s-2.1 2.8-2.1 2.8-.3 2.7.7 2.7" />,
  phone: (
    <g>
      <rect x="7" y="3" width="10" height="18" rx="2.4" />
      <path d="M10.5 18h3" />
    </g>
  ),
};

export default function Icon({ name, size = 20, stroke = 1.75, className, style }) {
  return (
    <svg
      className={className}
      style={style}
      width={size}
      height={size}
      viewBox="0 0 24 24"
      fill="none"
      stroke="currentColor"
      strokeWidth={stroke}
      strokeLinecap="round"
      strokeLinejoin="round"
      aria-hidden="true"
    >
      {P[name]}
    </svg>
  );
}
