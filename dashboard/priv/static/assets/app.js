// The whole client: connect the LiveView socket. The two libraries are the
// prebuilt files shipped in the phoenix and phoenix_live_view packages.
(function () {
  "use strict";
  var token = document.querySelector("meta[name='csrf-token']").getAttribute("content");
  var liveSocket = new window.LiveView.LiveSocket("/live", window.Phoenix.Socket, {
    params: { _csrf_token: token },
  });
  liveSocket.connect();
  window.liveSocket = liveSocket;
})();

// Theme: follow the system unless the reader picks one; remembered per browser.
(function () {
  "use strict";
  var order = ["auto", "light", "dark"];
  var stored = null;
  try {
    stored = window.localStorage.getItem("theme");
  } catch (error) {
    stored = null;
  }
  var theme = order.indexOf(stored) >= 0 ? stored : "auto";

  function apply() {
    if (theme === "auto") {
      document.documentElement.removeAttribute("data-theme");
    } else {
      document.documentElement.setAttribute("data-theme", theme);
    }
    var button = document.getElementById("theme-toggle");
    if (button) button.textContent = "Theme: " + theme;
  }

  apply();
  window.addEventListener("phx:page-loading-stop", apply);
  document.addEventListener("click", function (event) {
    if (!event.target || event.target.id !== "theme-toggle") return;
    theme = order[(order.indexOf(theme) + 1) % order.length];
    try {
      window.localStorage.setItem("theme", theme);
    } catch (error) {
      // Private browsing: the choice lasts for this page only.
    }
    apply();
  });
})();
