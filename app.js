/* MUSD Goals — app.js (classic script, ethers v6 UMD, no modules) */
(function () {
  "use strict";

  var CFG = window.APP_CONFIG || {};
  var CHAIN_ID = CFG.chainId || 31611;
  var CHAIN_HEX = CFG.chainIdHex || "0x7B7B";
  var RPC_URL = CFG.rpcUrl || "https://rpc.test.mezo.org";
  var EXPLORER = (CFG.explorer || "https://explorer.test.mezo.org").replace(/\/$/, "");
  var PENDING = "DEPLOY_PENDING";

  var ERC20_ABI = [
    "function balanceOf(address) view returns (uint256)",
    "function approve(address spender, uint256 amount) returns (bool)",
    "function allowance(address owner, address spender) view returns (uint256)",
    "function decimals() view returns (uint8)",
    "function symbol() view returns (string)",
    "function faucet()"
  ];

  var GOALS_ABI = [
    "function createGoal(string name, uint256 target, uint256 deadline) returns (uint256)",
    "function deposit(uint256 goalId, uint256 amount)",
    "function withdraw(uint256 goalId, uint256 amount)",
    "function getGoals(address user) view returns (tuple(string name, uint256 target, uint256 saved, uint64 deadline, bool active)[])",
    "function goalCount(address) view returns (uint256)",
    "function token() view returns (address)"
  ];

  // ---------- State ----------
  var state = {
    mode: "real", // 'real' | 'demo'
    account: null,
    chainId: null,
    provider: null, // ethers BrowserProvider
    signer: null,
    goals: [], // last fetched goals
    busy: false
  };

  // ---------- DOM ----------
  function $(id) { return document.getElementById(id); }
  var el = {};
  [
    "connectBtn","accountBox","accountAddress","disconnectBtn","networkPill","networkPillText",
    "networkBanner","switchNetworkBtn","noWalletBanner","pendingBanner","pendingBannerText",
    "statusBar","modeRealBtn","modeDemoBtn","demoPanel","realPanel","faucetBtn",
    "tokenBalance","tokenSymbol","totalSaved","goalCount","refreshBtn",
    "createForm","goalName","goalTarget","goalDeadline","createBtn",
    "goalsList","goalsEmpty","goalsHeadHint","footerModeLabel","footerTokenAddr","footerGoalsAddr"
  ].forEach(function (id) { el[id] = $(id); });
  // token-symbol-label spans (class-based)
  function tokenSymbolLabels() { return document.querySelectorAll(".token-symbol-label"); }

  // ---------- Helpers ----------
  function isPending(addr) { return !addr || addr === PENDING; }
  function shortAddr(a) { return a ? a.slice(0, 6) + "…" + a.slice(-4) : "—"; }
  function explorerAddr(a) { return EXPLORER + "/address/" + a; }
  function explorerTx(h) { return EXPLORER + "/tx/" + h; }
  function esc(s) {
    return String(s == null ? "" : s).replace(/[&<>"']/g, function (c) {
      return { "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c];
    });
  }
  function modeConfig() {
    if (state.mode === "demo") return { token: CFG.demoMusd, goals: CFG.goalsDemo, symbol: "dMUSD", label: "Demo MUSD mode" };
    return { token: CFG.realMusd, goals: CFG.goalsReal, symbol: "MUSD", label: "Real MUSD mode" };
  }
  function modeDeployed() {
    var c = modeConfig();
    return !isPending(c.token) && !isPending(c.goals);
  }
  function fmt(amountBn, decimals) {
    try {
      var s = ethers.formatUnits(amountBn, decimals == null ? 18 : decimals);
      // Trim to max 4 dp for display, keep exact-ish readability
      if (s.indexOf(".") >= 0) {
        var parts = s.split(".");
        if (parts[1].length > 4) s = parts[0] + "." + parts[1].slice(0, 4).replace(/0+$/, "");
        if (s.endsWith(".")) s = s.slice(0, -1);
      }
      // thousands separators on integer part
      var neg = s.startsWith("-"); if (neg) s = s.slice(1);
      var ip = s.split(".")[0], fp = s.split(".")[1];
      ip = ip.replace(/\B(?=(\d{3})+(?!\d))/g, ",");
      return (neg ? "-" : "") + ip + (fp ? "." + fp : "");
    } catch (e) { return "—"; }
  }
  function parseAmount(str) {
    // returns BigInt (wei) or null if invalid
    if (str == null) return null;
    str = String(str).trim().replace(",", ".");
    if (!str || isNaN(Number(str)) || Number(str) <= 0) return null;
    try { return ethers.parseUnits(str, 18); } catch (e) { return null; }
  }
  function fmtDate(ts) {
    if (!ts || Number(ts) === 0) return "";
    var d = new Date(Number(ts) * 1000);
    return d.toLocaleDateString(undefined, { year: "numeric", month: "short", day: "numeric" });
  }

  function setStatus(msg, kind, txHash) {
    if (!msg) { el.statusBar.classList.add("hidden"); el.statusBar.innerHTML = ""; return; }
    el.statusBar.className = "status-bar " + (kind || "info");
    var html = esc(msg);
    if (txHash) html += ' <a class="tx-link" href="' + explorerTx(txHash) + '" target="_blank" rel="noopener">View tx on explorer ↗</a>';
    el.statusBar.innerHTML = html;
    el.statusBar.classList.remove("hidden");
  }
  function humanError(e) {
    if (!e) return "Something went wrong. Please try again.";
    var code = e.code || (e.info && e.info.error && e.info.error.code);
    var msg = (e.shortMessage || e.message || String(e));
    if (code === "ACTION_REJECTED" || code === 4001 || /user rejected|user denied|rejected the request/i.test(msg)) {
      return "Transaction rejected in your wallet — nothing was sent.";
    }
    if (/insufficient funds/i.test(msg)) return "Insufficient funds for gas (you need a little test BTC on Mezo Testnet) or for this amount.";
    if (/insufficient|exceeds balance|transfer amount exceeds/i.test(msg)) return "Insufficient token balance for that amount. Check your balance and try a smaller amount.";
    if (/network|chain|CHAIN/i.test(msg) && /mismatch|not connected|unknown/i.test(msg)) return "Wrong network — please switch to Mezo Testnet (Chain 31611).";
    // Strip ethers' long call dumps for readability
    if (msg.length > 220) msg = msg.slice(0, 220) + "…";
    return msg;
  }

  // ---------- Contracts ----------
  function getProvider() {
    if (!window.ethereum) return null;
    if (!state.provider) state.provider = new ethers.BrowserProvider(window.ethereum);
    return state.provider;
  }
  function tokenContract(withSigner) {
    var c = modeConfig();
    if (isPending(c.token)) return null;
    var runner = withSigner && state.signer ? state.signer : getProvider();
    if (!runner) return null;
    return new ethers.Contract(c.token, ERC20_ABI, runner);
  }
  function goalsContract(withSigner) {
    var c = modeConfig();
    if (isPending(c.goals)) return null;
    var runner = withSigner && state.signer ? state.signer : getProvider();
    if (!runner) return null;
    return new ethers.Contract(c.goals, GOALS_ABI, runner);
  }

  // ---------- Network ----------
  function isCorrectNetwork() { return state.chainId === CHAIN_ID; }
  function updateNetworkUI() {
    var connected = !!state.account;
    el.networkPill.classList.toggle("hidden", !connected);
    el.networkBanner.classList.toggle("hidden", !(connected && !isCorrectNetwork()));
    if (connected) {
      el.networkPillText.textContent = isCorrectNetwork() ? "Mezo Testnet · 31611" : "Wrong network · Chain " + state.chainId;
      el.networkPill.classList.toggle("wrong", !isCorrectNetwork());
    }
  }
  async function switchNetwork() {
    if (!window.ethereum) return;
    try {
      await window.ethereum.request({ method: "wallet_switchEthereumChain", params: [{ chainId: CHAIN_HEX }] });
    } catch (e) {
      // 4902 = chain not added
      if (e && (e.code === 4902 || /not added|Unrecognized chain/i.test(e.message || ""))) {
        try {
          await window.ethereum.request({
            method: "wallet_addEthereumChain",
            params: [{
              chainId: CHAIN_HEX,
              chainName: "Mezo Testnet",
              rpcUrls: [RPC_URL],
              blockExplorerUrls: [EXPLORER],
              nativeCurrency: { name: "Bitcoin", symbol: "BTC", decimals: 18 }
            }]
          });
        } catch (e2) { setStatus(humanError(e2), "error"); return; }
      } else { setStatus(humanError(e), "error"); return; }
    }
    // chainChanged listener refreshes; also poll once
    try {
      var p = getProvider();
      if (p) { var n = await p.getNetwork(); state.chainId = Number(n.chainId); updateNetworkUI(); refreshAll(); }
    } catch (err) { /* listener will handle */ }
  }

  // ---------- Wallet ----------
  async function connect() {
    if (!window.ethereum) { el.noWalletBanner.classList.remove("hidden"); return; }
    if (typeof ethers === "undefined") { setStatus("ethers.js failed to load — check your connection and reload.", "error"); return; }
    try {
      el.connectBtn.disabled = true;
      el.connectBtn.innerHTML = '<span class="spinner"></span> Connecting…';
      var provider = getProvider();
      await provider.send("eth_requestAccounts", []);
      state.signer = await provider.getSigner();
      state.account = await state.signer.getAddress();
      var net = await provider.getNetwork();
      state.chainId = Number(net.chainId);
      updateWalletUI();
      updateNetworkUI();
      if (!isCorrectNetwork()) {
        setStatus("Wallet connected, but you're not on Mezo Testnet yet — use the Switch button above.", "info");
      } else {
        setStatus("Wallet connected: " + shortAddr(state.account), "success");
      }
      refreshAll();
    } catch (e) {
      setStatus(humanError(e), "error");
    } finally {
      el.connectBtn.disabled = false;
      el.connectBtn.textContent = "Connect Wallet";
    }
  }
  function disconnectLocal() {
    state.account = null; state.signer = null; state.goals = [];
    updateWalletUI(); updateNetworkUI(); renderGoals(); updateFooter();
    el.tokenBalance.textContent = "—"; el.totalSaved.textContent = "—"; el.goalCount.textContent = "—";
    setStatus("Disconnected locally. To fully disconnect, also remove this site in your wallet settings.", "info");
  }
  function updateWalletUI() {
    var connected = !!state.account;
    el.connectBtn.classList.toggle("hidden", connected);
    el.accountBox.classList.toggle("hidden", !connected);
    if (connected) el.accountAddress.textContent = shortAddr(state.account);
    el.goalsHeadHint.textContent = connected ? "" : "Connect your wallet to see your jars";
  }

  // ---------- Mode ----------
  function setMode(mode) {
    state.mode = mode;
    el.modeRealBtn.classList.toggle("active", mode === "real");
    el.modeDemoBtn.classList.toggle("active", mode === "demo");
    el.modeRealBtn.setAttribute("aria-selected", mode === "real" ? "true" : "false");
    el.modeDemoBtn.setAttribute("aria-selected", mode === "demo" ? "true" : "false");
    el.demoPanel.classList.toggle("hidden", mode !== "demo");
    el.realPanel.classList.toggle("hidden", mode !== "real");
    var c = modeConfig();
    el.tokenSymbol.textContent = c.symbol;
    tokenSymbolLabels().forEach(function (n) { n.textContent = c.symbol; });
    var deployed = modeDeployed();
    el.pendingBanner.classList.toggle("hidden", deployed);
    if (!deployed) {
      var missing = [];
      if (isPending(c.token)) missing.push(c.symbol + " token");
      if (isPending(c.goals)) missing.push("MUSDGoals contract");
      el.pendingBannerText.textContent = "Deployment pending for this mode (" + missing.join(" + ") + " not deployed yet). Balances and jars will appear here automatically once deployed.";
    }
    el.faucetBtn.disabled = !deployed;
    el.createBtn.disabled = !deployed;
    updateFooter();
    refreshAll();
  }
  function updateFooter() {
    var c = modeConfig();
    el.footerModeLabel.textContent = c.label;
    el.footerTokenAddr.innerHTML = isPending(c.token)
      ? '<span class="muted">DEPLOY_PENDING</span>'
      : '<a href="' + explorerAddr(c.token) + '" target="_blank" rel="noopener">' + esc(c.token) + '</a>';
    el.footerGoalsAddr.innerHTML = isPending(c.goals)
      ? '<span class="muted">DEPLOY_PENDING</span>'
      : '<a href="' + explorerAddr(c.goals) + '" target="_blank" rel="noopener">' + esc(c.goals) + '</a>';
  }

  // ---------- Data ----------
  async function refreshAll() {
    updateFooter();
    if (!state.account || !isCorrectNetwork() || !modeDeployed()) {
      if (!modeDeployed()) {
        el.tokenBalance.textContent = "—"; el.totalSaved.textContent = "—"; el.goalCount.textContent = "—";
        state.goals = []; renderGoals();
      }
      return;
    }
    await Promise.all([refreshBalance(), refreshGoals()]);
  }
  async function refreshBalance() {
    try {
      var tc = tokenContract(false);
      if (!tc || !state.account) return;
      var bal = await tc.balanceOf(state.account);
      el.tokenBalance.textContent = fmt(bal);
    } catch (e) { el.tokenBalance.textContent = "—"; }
  }
  async function refreshGoals() {
    try {
      var gc = goalsContract(false);
      if (!gc || !state.account) return;
      var raw = await gc.getGoals(state.account);
      state.goals = [];
      for (var i = 0; i < raw.length; i++) {
        var g = raw[i];
        state.goals.push({
          id: i,
          name: g.name != null ? g.name : g[0],
          target: g.target != null ? g.target : g[1],
          saved: g.saved != null ? g.saved : g[2],
          deadline: g.deadline != null ? Number(g.deadline) : Number(g[3]),
          active: g.active != null ? g.active : g[4]
        });
      }
      renderGoals();
      // totals
      var total = 0n;
      state.goals.forEach(function (g) { if (g.active) total += BigInt(g.saved.toString()); });
      el.totalSaved.textContent = fmt(total) + " " + modeConfig().symbol;
      el.goalCount.textContent = String(state.goals.filter(function (g) { return g.active; }).length);
    } catch (e) {
      // getGoals failing usually = contract not ready / RPC hiccup — surface it, don't crash
      setStatus("Could not load your goals: " + humanError(e), "error");
    }
  }

  // ---------- Render goals ----------
  function renderGoals() {
    var list = el.goalsList;
    list.innerHTML = "";
    var has = state.goals.length > 0;
    el.goalsEmpty.classList.toggle("hidden", has);
    if (has) el.goalsEmpty.style.display = "none"; else el.goalsEmpty.style.display = "";
    // When not connected / pending, keep the friendly empty state text as-is.
    state.goals.forEach(function (g) {
      var target = BigInt(g.target.toString());
      var saved = BigInt(g.saved.toString());
      var pct = target === 0n ? 100 : Number((saved * 10000n) / target) / 100;
      if (pct > 100) pct = 100;
      var achieved = target > 0n && saved >= target;
      var sym = modeConfig().symbol;

      var card = document.createElement("article");
      card.className = "goal-card";
      var deadlineTxt = g.deadline ? " · Deadline: " + esc(fmtDate(g.deadline)) : "";
      var badge = !g.active
        ? '<span class="badge badge-inactive">Closed</span>'
        : achieved
          ? '<span class="badge badge-achieved">🎉 Achieved</span>'
          : '<span class="badge badge-active">Saving</span>';

      card.innerHTML =
        '<div class="goal-top"><div><h3 class="goal-name">' + esc(g.name || ("Goal #" + (g.id + 1))) + '</h3>' +
        '<div class="goal-meta">Jar #' + (g.id + 1) + deadlineTxt + '</div></div>' + badge + '</div>' +
        '<div class="progress-wrap"><div class="progress-track"><div class="progress-fill' + (achieved ? " done" : "") + '" style="width:' + pct + '%"></div></div>' +
        '<div class="progress-labels"><span><strong>' + esc(fmt(saved)) + '</strong> <span class="muted">of ' + esc(fmt(target)) + ' ' + sym + '</span></span>' +
        '<span class="pct' + (achieved ? " done" : "") + '">' + pct.toFixed(pct % 1 === 0 ? 0 : 1) + '% funded</span></div></div>' +
        '<div class="goal-actions">' +
          '<div class="action-box"><span class="label">Deposit ' + sym + '</span><div class="action-row">' +
            '<input type="number" inputmode="decimal" min="0" step="any" placeholder="100" data-role="deposit-amount" />' +
            '<button class="btn btn-primary btn-sm" data-action="deposit" data-id="' + g.id + '">Deposit</button></div></div>' +
          '<div class="action-box"><span class="label">Withdraw ' + sym + '</span><div class="action-row">' +
            '<input type="number" inputmode="decimal" min="0" step="any" placeholder="50" data-role="withdraw-amount" />' +
            '<button class="btn btn-secondary btn-sm" data-action="withdraw" data-id="' + g.id + '">Withdraw</button></div></div>' +
        '</div>' +
        '<div class="goal-tx hidden" data-role="tx"></div>';

      list.appendChild(card);
    });

    // Wire action buttons (event delegation would also work; explicit is clearer)
    list.querySelectorAll("button[data-action]").forEach(function (btn) {
      btn.addEventListener("click", function () {
        var card = btn.closest(".goal-card");
        var action = btn.getAttribute("data-action");
        var id = Number(btn.getAttribute("data-id"));
        var input = card.querySelector('input[data-role="' + action + '-amount"]');
        var txBox = card.querySelector('[data-role="tx"]');
        if (action === "deposit") doDeposit(id, input, btn, txBox);
        else doWithdraw(id, input, btn, txBox);
      });
    });
  }

  // ---------- Tx helper ----------
  async function sendAndWait(label, txPromise, btn, txBox) {
    var orig = btn ? btn.textContent : "";
    try {
      if (btn) { btn.disabled = true; btn.innerHTML = '<span class="spinner"></span> Confirm in wallet…'; }
      var tx = await txPromise;
      if (txBox) {
        txBox.classList.remove("hidden");
        txBox.innerHTML = label + ' sent — waiting for confirmation… <a href="' + explorerTx(tx.hash) + '" target="_blank" rel="noopener">' + esc(shortAddr(tx.hash)) + ' ↗</a>';
      }
      setStatus(label + " sent — waiting for confirmation…", "info", tx.hash);
      if (btn) btn.innerHTML = '<span class="spinner"></span> Confirming…';
      var receipt = await tx.wait();
      if (receipt && receipt.status === 0) throw new Error("Transaction reverted on-chain.");
      setStatus(label + " confirmed ✓", "success", tx.hash);
      return tx;
    } finally {
      if (btn) { btn.disabled = false; btn.textContent = orig; }
    }
  }
  function requireReady() {
    if (!window.ethereum) { setStatus("No wallet detected — install MetaMask and reload.", "error"); return false; }
    if (!state.account) { setStatus("Connect your wallet first.", "error"); return false; }
    if (!isCorrectNetwork()) { setStatus("Wrong network — switch to Mezo Testnet (Chain 31611) first.", "error"); updateNetworkUI(); return false; }
    if (!modeDeployed()) { setStatus("This mode is not deployed yet (deployment pending).", "error"); return false; }
    return true;
  }

  // ---------- Actions ----------
  async function doFaucet() {
    if (!requireReady()) return;
    if (state.mode !== "demo") return;
    var btn = el.faucetBtn;
    try {
      var tc = tokenContract(true);
      await sendAndWait("Faucet mint (1,000 dMUSD)", tc.faucet(), btn, null);
      await refreshAll();
    } catch (e) { setStatus(humanError(e), "error"); }
  }

  async function onCreate(ev) {
    ev.preventDefault();
    if (!requireReady()) return;
    var name = el.goalName.value.trim();
    var target = parseAmount(el.goalTarget.value);
    if (!name) { setStatus("Give your goal a name first.", "error"); el.goalName.focus(); return; }
    if (target === null) { setStatus("Enter a valid target amount greater than 0.", "error"); el.goalTarget.focus(); return; }
    var deadline = 0;
    if (el.goalDeadline.value) {
      var d = new Date(el.goalDeadline.value + "T23:59:59");
      deadline = Math.floor(d.getTime() / 1000);
      if (isNaN(deadline) || deadline <= Math.floor(Date.now() / 1000)) {
        setStatus("Deadline must be in the future.", "error"); return;
      }
    }
    var btn = el.createBtn;
    try {
      var gc = goalsContract(true);
      await sendAndWait("Goal created", gc.createGoal(name, target, deadline), btn, null);
      el.createForm.reset();
      await refreshAll();
    } catch (e) { setStatus(humanError(e), "error"); }
  }

  async function doDeposit(goalId, input, btn, txBox) {
    if (!requireReady()) return;
    var amount = parseAmount(input && input.value);
    if (amount === null) { setStatus("Enter a valid deposit amount greater than 0.", "error"); if (input) input.focus(); return; }
    try {
      // Balance pre-check for a friendlier error than a revert
      var tcRead = tokenContract(false);
      var bal = await tcRead.balanceOf(state.account);
      if (BigInt(bal.toString()) < amount) {
        setStatus("Insufficient " + modeConfig().symbol + " balance — you have " + fmt(bal) + " but tried to deposit " + fmt(amount) + ".", "error");
        return;
      }
      var gc = goalsContract(true);
      var tc = tokenContract(true);
      var goalsAddr = modeConfig().goals;

      // Approve exact amount first if allowance is insufficient (spec requirement)
      var allowance = await tc.allowance(state.account, goalsAddr);
      if (BigInt(allowance.toString()) < amount) {
        setStatus("Step 1 of 2: approve the exact deposit amount in your wallet…", "info");
        await sendAndWait("Approve", tc.approve(goalsAddr, amount), btn, txBox);
        setStatus("Approved ✓ — now confirm the deposit (step 2 of 2)…", "info");
      }
      await sendAndWait("Deposit", gc.deposit(goalId, amount), btn, txBox);
      if (input) input.value = "";
      await refreshAll();
    } catch (e) { setStatus(humanError(e), "error"); }
  }

  async function doWithdraw(goalId, input, btn, txBox) {
    if (!requireReady()) return;
    var amount = parseAmount(input && input.value);
    if (amount === null) { setStatus("Enter a valid withdraw amount greater than 0.", "error"); if (input) input.focus(); return; }
    var goal = state.goals[goalId];
    if (goal && BigInt(goal.saved.toString()) < amount) {
      setStatus("You can't withdraw more than this jar holds (" + fmt(goal.saved) + " " + modeConfig().symbol + " saved).", "error");
      return;
    }
    try {
      var gc = goalsContract(true);
      await sendAndWait("Withdrawal", gc.withdraw(goalId, amount), btn, txBox);
      if (input) input.value = "";
      await refreshAll();
    } catch (e) { setStatus(humanError(e), "error"); }
  }

  // ---------- Init / listeners ----------
  function init() {
    if (!window.ethereum) el.noWalletBanner.classList.remove("hidden");
    if (typeof ethers === "undefined") setStatus("ethers.js CDN failed to load — check your connection and reload the page.", "error");

    el.connectBtn.addEventListener("click", connect);
    el.disconnectBtn.addEventListener("click", disconnectLocal);
    el.switchNetworkBtn.addEventListener("click", switchNetwork);
    el.modeRealBtn.addEventListener("click", function () { setMode("real"); });
    el.modeDemoBtn.addEventListener("click", function () { setMode("demo"); });
    el.faucetBtn.addEventListener("click", doFaucet);
    el.createForm.addEventListener("submit", onCreate);
    el.refreshBtn.addEventListener("click", function () { refreshAll(); });

    if (window.ethereum) {
      window.ethereum.on("accountsChanged", function (accounts) {
        if (!accounts || accounts.length === 0) { disconnectLocal(); return; }
        state.account = accounts[0];
        // Refresh signer for the new account
        var p = getProvider();
        if (p) p.getSigner().then(function (s) { state.signer = s; updateWalletUI(); refreshAll(); }).catch(function () {});
        updateWalletUI();
      });
      window.ethereum.on("chainChanged", function (hex) {
        state.chainId = parseInt(hex, 16);
        // ethers BrowserProvider caches network; recreate it
        state.provider = null; state.signer = null;
        var p = getProvider();
        if (state.account && p) p.getSigner().then(function (s) { state.signer = s; }).catch(function () {});
        updateNetworkUI();
        refreshAll();
      });

      // Silent reconnect if already authorized
      try {
        var provider = getProvider();
        provider.send("eth_accounts", []).then(async function (accounts) {
          if (accounts && accounts.length > 0) {
            state.signer = await provider.getSigner();
            state.account = await state.signer.getAddress();
            var net = await provider.getNetwork();
            state.chainId = Number(net.chainId);
            updateWalletUI(); updateNetworkUI(); refreshAll();
          }
        }).catch(function () {});
      } catch (e) { /* ignore — user can click Connect */ }
    }

    setMode("real");
    updateWalletUI();
    updateNetworkUI();
  }

  if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", init);
  else init();
})();
