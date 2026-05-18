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
    var items = Array.prototype.slice.call(list.querySelectorAll("[data-sympp-stream-id]"));

    items.forEach(function (item, index) {
      var id = item.getAttribute("data-sympp-stream-id");
      var pinned = pins.indexOf(id) !== -1;
      var pin = item.querySelector("[data-sympp-stream-pin]");

      if (!item.dataset.symppOriginalIndex) item.dataset.symppOriginalIndex = String(index);
      item.dataset.symppPinned = pinned ? "true" : "false";
      item.classList.toggle("pinned", pinned);

      if (pin) {
        pin.setAttribute("aria-pressed", pinned ? "true" : "false");
        pin.setAttribute("title", pinned ? "Unpin stream" : "Pin stream");
        pin.textContent = pinned ? "Unpin" : "Pin";
      }
    });

    var desiredItems = items.slice().sort(function (left, right) {
      var leftPinIndex = pins.indexOf(left.getAttribute("data-sympp-stream-id"));
      var rightPinIndex = pins.indexOf(right.getAttribute("data-sympp-stream-id"));
      var leftPinned = leftPinIndex !== -1;
      var rightPinned = rightPinIndex !== -1;

      if (leftPinned && rightPinned) return leftPinIndex - rightPinIndex;
      if (leftPinned) return -1;
      if (rightPinned) return 1;

      return Number(left.dataset.symppOriginalIndex) - Number(right.dataset.symppOriginalIndex);
    });

    var currentIds = items.map(function (stream) {
      return stream.getAttribute("data-sympp-stream-id");
    });

    var desiredIds = desiredItems.map(function (stream) {
      return stream.getAttribute("data-sympp-stream-id");
    });

    if (currentIds.join("\n") === desiredIds.join("\n")) return;

    desiredItems.forEach(function (item) {
      list.appendChild(item);
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
