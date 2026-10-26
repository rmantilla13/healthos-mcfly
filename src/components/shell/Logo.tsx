// The healthOS mark: a sunburst of 24 rays round a dot. In the sidebar, the phone's top bar and the sign-in card.
export function Logo({ size = 30 }: { size?: number }) {
  return (
    <svg width={size} height={size} viewBox="0 0 32 32" aria-hidden="true" className="logo">
      <g fill="none" stroke="currentColor" strokeWidth="1.1" strokeLinecap="round">
        {Array.from({ length: 24 }, (_, i) => {
          const a = (i / 24) * Math.PI * 2;
          const r1 = 5 + (i % 2) * 1.5;
          const r2 = 13 - (i % 3);
          return <line key={i} x1={16 + r1 * Math.cos(a)} y1={16 + r1 * Math.sin(a)} x2={16 + r2 * Math.cos(a)} y2={16 + r2 * Math.sin(a)} />;
        })}
      </g>
      <circle cx="16" cy="16" r="2.4" fill="currentColor" />
    </svg>
  );
}
