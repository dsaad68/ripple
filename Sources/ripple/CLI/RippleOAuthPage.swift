import Foundation

/// The "Signed in" page ripple serves on the OAuth loopback callback after a `/mcp` (or
/// `ripple mcp login`) sign-in - ripple's own dark-glass card in its blue -> purple palette, with
/// concentric "ripple" rings around the check. Self-contained (inline CSS/SVG); passed into
/// ``SwiftSDKMCPSession`` by ``MCPRuntime/login(_:force:)`` so the framework's Mispher default
/// (``MCPOAuthSuccessPage/mispher``) is overridden only for ripple.
enum RippleOAuthPage {
    static let signedIn = """
    <!doctype html>
    <html lang="en">
    <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <title>ripple - Signed in</title>
    <style>
      :root { --accent:#6cb6ff; --accent2:#bd9cff; --fg:#eef2f6; --fg2:#97a3b0; }
      * { box-sizing:border-box; margin:0; }
      html, body { height:100%; }
      body {
        font-family:-apple-system,BlinkMacSystemFont,"SF Pro Text","Segoe UI",system-ui,sans-serif;
        color:var(--fg);
        background:
          radial-gradient(1100px 680px at 50% -12%, rgba(108,182,255,.12), transparent 60%),
          radial-gradient(820px 560px at 86% 116%, rgba(189,156,255,.10), transparent 55%),
          linear-gradient(160deg,#0d0f15,#101317 55%,#12131a);
        display:flex; align-items:center; justify-content:center; padding:24px;
        -webkit-font-smoothing:antialiased;
      }
      .card {
        width:min(440px,92vw); text-align:center; padding:46px 40px 34px;
        background:linear-gradient(180deg, rgba(22,26,33,.86), rgba(13,15,21,.86));
        border:1px solid rgba(255,255,255,.08); border-radius:22px;
        box-shadow:0 26px 70px -24px rgba(0,0,0,.65), inset 0 1px 0 rgba(255,255,255,.05);
        backdrop-filter:blur(14px); animation:rise .55s cubic-bezier(.2,.8,.2,1) both;
      }
      .badge {
        position:relative; width:84px; height:84px; margin:0 auto 24px; border-radius:50%;
        display:grid; place-items:center;
        background:radial-gradient(circle at 50% 34%, rgba(108,182,255,.30), rgba(189,156,255,.06));
        box-shadow:0 0 0 1px rgba(108,182,255,.35), 0 0 44px rgba(108,182,255,.26);
        animation:pop .5s .12s cubic-bezier(.2,1.3,.4,1) both;
      }
      .badge::before, .badge::after {
        content:""; position:absolute; inset:0; border-radius:50%;
        border:1px solid rgba(108,182,255,.40); animation:ripple 2.2s ease-out infinite;
      }
      .badge::after { animation-delay:1.1s; }
      .badge svg {
        width:38px; height:38px; fill:none; stroke:url(#g); stroke-width:3.1;
        stroke-linecap:round; stroke-linejoin:round;
        stroke-dasharray:30; stroke-dashoffset:30; animation:draw .5s .34s ease forwards;
      }
      h1 { font-size:22px; font-weight:600; letter-spacing:-.012em; }
      p { margin-top:11px; font-size:13.5px; line-height:1.55; color:var(--fg2); }
      .brand {
        margin-top:28px; font-size:13px; letter-spacing:.30em; font-weight:700;
        background:linear-gradient(90deg,var(--accent),var(--accent2));
        -webkit-background-clip:text; background-clip:text; color:transparent; opacity:.95;
      }
      @keyframes rise   { from{opacity:0; transform:translateY(12px) scale(.985)} to{opacity:1; transform:none} }
      @keyframes pop    { from{opacity:0; transform:scale(.6)} to{opacity:1; transform:none} }
      @keyframes draw   { to{stroke-dashoffset:0} }
      @keyframes ripple { from{transform:scale(1); opacity:.55} to{transform:scale(1.7); opacity:0} }
    </style>
    </head>
    <body>
      <main class="card">
        <div class="badge">
          <svg viewBox="0 0 24 24">
            <defs><linearGradient id="g" x1="0" y1="0" x2="1" y2="1">
              <stop offset="0" stop-color="#6cb6ff"/><stop offset="1" stop-color="#bd9cff"/>
            </linearGradient></defs>
            <path d="M5 12.5l4.2 4.2L19 7"/>
          </svg>
        </div>
        <h1>Signed in</h1>
        <p>You're connected. You can close this window and return to ripple.</p>
        <div class="brand">ripple</div>
      </main>
      <script>setTimeout(function(){ try { window.close(); } catch (e) {} }, 2200);</script>
    </body>
    </html>
    """
}
