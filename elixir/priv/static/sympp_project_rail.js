(function () {
  var storageKey = "sympp.projectRail.pins.v1";
  var applyScheduled = false;

  function readPins() {
    try {
      var raw = window.localStorage && window.localStorage.getItem(storageKey);
      var pins = raw ? JSON.parse(raw) : [];
      return Array.isArray(pins) ? pins.filter(function (pin) { return typeof pin === "string"; }) : [];
    } catch (_error) {
      return [];
    }
  }

  function writePins(pins) {
    try {
      if (window.localStorage) window.localStorage.setItem(storageKey, JSON.stringify(pins));
    } catch (_error) {
    }
  }

  function applyPins(rail) {
    var pins = readPins();
    var list = rail.querySelector(".sympp-stream-list");
    if (!list) return;
    var pinnedItems = [];

    Array.prototype.forEach.call(list.querySelectorAll("[data-sympp-stream-id]"), function (item) {
      var id = item.getAttribute("data-sympp-stream-id");
      var pinned = pins.indexOf(id) !== -1;
      var pin = item.querySelector("[data-sympp-stream-pin]");

      item.dataset.symppPinned = pinned ? "true" : "false";
      item.classList.toggle("pinned", pinned);
      if (pinned) pinnedItems.push(item);

      if (pin) {
        pin.setAttribute("aria-pressed", pinned ? "true" : "false");
        pin.setAttribute("title", pinned ? "Unpin stream" : "Pin stream");
        pin.textContent = pinned ? "Unpin" : "Pin";
      }
    });

    var orderedPinnedItems = pins.map(function (id) {
      return Array.prototype.find.call(pinnedItems, function (stream) {
        return stream.getAttribute("data-sympp-stream-id") === id;
      });
    }).filter(Boolean);

    var currentPinnedIds = [];
    Array.prototype.some.call(list.children, function (stream) {
      if (stream.getAttribute("data-sympp-pinned") !== "true") return true;
      currentPinnedIds.push(stream.getAttribute("data-sympp-stream-id"));
      return false;
    });

    var orderedPinnedIds = orderedPinnedItems.map(function (stream) {
      return stream.getAttribute("data-sympp-stream-id");
    });

    if (currentPinnedIds.join("\n") === orderedPinnedIds.join("\n")) return;

    orderedPinnedItems.slice().reverse().forEach(function (item) {
      list.insertBefore(item, list.firstChild);
    });
  }

  function togglePin(button) {
    var item = button.closest("[data-sympp-stream-id]");
    if (!item) return;

    var id = item.getAttribute("data-sympp-stream-id");
    var pins = readPins();
    var index = pins.indexOf(id);

    if (index === -1) pins.unshift(id);
    else pins.splice(index, 1);

    writePins(pins);
    applyPins(item.closest("[data-sympp-project-rail]"));
  }

  function init() {
    Array.prototype.forEach.call(document.querySelectorAll("[data-sympp-project-rail]"), applyPins);
  }

  function scheduleInit() {
    if (applyScheduled) return;

    applyScheduled = true;
    (window.requestAnimationFrame || window.setTimeout)(function () {
      applyScheduled = false;
      init();
    });
  }

  document.addEventListener("click", function (event) {
    var button = event.target.closest && event.target.closest("[data-sympp-stream-pin]");
    if (!button) return;
    event.preventDefault();
    togglePin(button);
  });

  document.addEventListener("DOMContentLoaded", init);
  window.addEventListener("phx:update", scheduleInit);
  window.addEventListener("phx:page-loading-stop", scheduleInit);

  if (window.MutationObserver) {
    new MutationObserver(scheduleInit).observe(document.body, { childList: true, subtree: true });
  }
})();
