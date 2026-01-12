Here is a professional `README.md` designed specifically for your public brand repository. It incorporates the technical specs we discussed—ensuring anyone who wants to contribute or use your brand assets has the exact font and color information.

---

# 📁 TunnelSats Brand Identity & Assets

This repository serves as the official, verifiable source for all **TunnelSats** visual assets. It is automatically synced from our core development environment to ensure the community always has access to the latest brand resources.

## 🎨 Visual Identity

### Typography

We use **Inter** for all digital interfaces and brand headings to ensure maximum readability and a modern, clean aesthetic.

* **Primary Font:** Inter
* **Weights:** Bold (700) for logos/headers; Regular (400) for body text.
* **Logo Tracking:** `-0.025em` (Tight).

### Color Palette

Our colors are inspired by the Bitcoin ecosystem and the security of "tunneled" connections.

| Element | Hex Code | Tailwind Class |
| --- | --- | --- |
| **Bitcoin Yellow** | `#FACC15` | `bg-bitcoin` |
| **Signal Green** | `#22C55E` | `bg-signal` |
| **Deep Background** | `#0F1115` | `bg-background` |
| **Pure White** | `#FFFFFF` | `text-white` |

---

## 📂 Repository Structure

* **/logos**: High-quality SVG and PNG versions of the TunnelSats logo (horizontal, stacked, and icon-only).
* **/icons**: UI icons and the TunnelSats Lightning bolt mark.
* **/social**: Banners and profile templates for X, Nostr, and Telegram.
* **/seasonal**: Special edition assets (e.g., Bitcoin Whitepaper themes, Santa Hat overlays).

---

## ⚖️ Usage Guidelines

We encourage the community to use these assets when:

1. Writing guides or documentation for TunnelSats node setups.
2. Featuring TunnelSats in Bitcoin-related news or newsletters.
3. Creating "Powered by TunnelSats" badges for personal node dashboards.

**Note:** Please do not use these assets in a way that implies an official partnership or endorsement by TunnelSats without prior consent.

---

## 🛠 For Developers & Designers

### Technical Specs for Reproduction

If you are recreating TunnelSats assets in tools like **Inkscape** or **Figma**:

* **Text:** "Tunnel" (White) | "Sats" (#FACC15).
* **Font Size Ratio:** If the font size is 100px, the letter spacing should be set to -2.5px.
* **Format:** Always prefer **SVG** for web implementation to maintain crispness at all scales.

---

### 🔄 Automation

This repository is a **mirror**. It is updated automatically via GitHub Actions whenever the `public/brand/` directory in our private core repository is updated.

**Maintained by the TunnelSats Team.**
[tunnelsats.com](https://tunnelsats.com) | [X](https://x.com/tunnelsats)
