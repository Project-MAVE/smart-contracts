# Ryodan Control design system

The first UI in this repository is an operator console for the Ryodan Keys NFT contract. Its visual identity combines the requested terminal / nerd / futuristic cyberpunk direction with the official Ryodan identity at https://ryodan.io/#world.

## Direction

A quiet, precise command deck: charcoal surfaces, vermilion red signals, warm amber warnings, technical typography and the original white Ryodan brushwork logo. Use thin rules, square corners and generous space around a dense working area. Avoid rainbow neon, excessive glow and ornamental charts that imply nonexistent data.

## Tokens

- Background `#0b0909`; sidebar `#100c0c`; panels `#181212`; raised surfaces `#231919`.
- Borders `#3a2929`; primary text `#f2e8e5`; muted text `#b49d99`.
- Official primary red `#e6332a`; deep action red `#c1272d`; readable red accents `#ff857b`; secondary rose `#d5a09a`; warning amber `#ffc078`; error `#ffb6ae`. Small red text uses the lighter accent; primary buttons use white text on deep red for contrast.
- Display: local `Impact`, `Haettenschweiler`, condensed sans-serif, uppercase. Utility/body: `SFMono-Regular`, `Consolas`, `Liberation Mono`, monospace. No remote font requests.
- Spacing: 4, 8, 12, 16, 24, 32, 48, 64 px. Panel padding 24–32 px.
- Radius: 2 px for controls, 0 px for panels, 50% only for status dots.
- Borders 1 px; focus rings 2 px light red with 3 px offset.

## Structure and components

- Desktop: 224 px persistent side navigation, flexible main area, compact upper connection bar, split headline/status panel, four metric columns, two-column work area.
- Mobile: compact header and horizontal wrapping navigation; single-column content, no horizontal page overflow.
- Primary button: deep red fill with white text; secondary button: border and transparent fill. Disabled controls remain legible and include a visible reason.
- Inputs have explicit labels, dark inset surfaces, clear validation, and fit within their grid cells. Addresses and URIs wrap; never inject untrusted metadata HTML.
- The four-phase strip is informational: equal columns on desktop, two columns on phones, a vermilion top rule on the current phase and muted closed phases. Mint has no phase picker. Operator configuration and irreversible advancement are separate controls.
- Allowlist preparation groups template downloads, three-file CSV input and UTC freeze time above a separate snapshot review/load form. Downloads wrap on narrow screens; CSV/date fields stack below 700 px. Hashes wrap as plain text. Generation/download remains distinct from a wallet-signed on-chain load.
- Transaction review uses a native accessible dialog with exact chain, contract, action, arguments and ETH value. Show pending hash and confirmed/reverted status in a persistent session activity log.
- Use chain-derived states. Loading, stale RPC, missing wallet, wrong network, permission denial and irreversible actions have distinct messages. Never present sample balances as live data.
- Transactions require wallet signing. Never put a private key or server-side automatic signer in the frontend.

## Motion and accessibility

One subtle entry transition and a restrained status pulse. Respect `prefers-reduced-motion`. Native buttons/forms, explicit labels, keyboard navigation, visible focus, `aria-live` feedback and dialog focus restoration. Desktop and mobile browser screenshots are required for UI verification.

## Brand assets

- `console/public/ryodan-logo.svg` is the unmodified official white logo from https://ryodan.io/assets/Ryodan_logo_white.svg, retrieved 2026-10-19. Use it in the sidebar and hero; do not redraw or distort it.
- `console/public/favicon.svg` is the official favicon from https://ryodan.io/assets/icons/favicon.svg?v=2.
- The official site defines `--red: #e6332a`; its deeper `#c1272d` also informs interactive surfaces. Keep the console dark, with restrained red grid lines around the white hero logo.
