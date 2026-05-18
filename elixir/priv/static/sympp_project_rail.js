(function () {
  var storageKey = "sympp.projectRail.pins.v1";

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

    Array.prototype.forEach.call(list.querySelectorAll("[data-sympp-stream-id]"), function (item) {
      var id = item.getAttribute("data-sympp-stream-id");
      var pinned = pins.indexOf(id) !== -1;
      var pin = item.querySelector("[data-sympp-stream-pin]");

      item.dataset.symppPinned = pinned ? "true" : "false";
      item.classList.toggle("pinned", pinned);

      if (pin) {
        pin.setAttribute("aria-pressed", pinned ? "true" : "false");
        pin.setAttribute("title", pinned ? "Unpin stream" : "Pin stream");
        pin.textContent = pinned ? "Unpin" : "Pin";
      }
    });

    pins.slice().reverse().forEach(function (id) {
      var item = Array.prototype.find.call(list.querySelectorAll("[data-sympp-stream-id]"), function (stream) {
        return stream.getAttribute("data-sympp-stream-id") === id;
      });

      if (item) list.insertBefore(item, list.firstChild);
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

  document.addEventListener("click", function (event) {
    var button = event.target.closest && event.target.closest("[data-sympp-stream-pin]");
    if (!button) return;
    event.preventDefault();
    togglePin(button);
  });

  document.addEventListener("DOMContentLoaded", init);
  window.addEventListener("phx:update", init);
})();
