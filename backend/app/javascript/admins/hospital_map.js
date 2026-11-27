const dialog = document.getElementById("hospital-map-picker");
const longitude = document.getElementById("hospital_address_longitude");
const latitude = document.getElementById("hospital_address_latitude");
const position = document.getElementById("hospital-map-position");
const readout = dialog.querySelector("[data-map-coordinate]");
const status = dialog.querySelector("[data-map-status]");
const confirm = dialog.querySelector("[data-map-confirm]");
const clear = dialog.querySelector("[data-map-clear]");
let map, tiles, marker, point;
let tilesReady = false;
let tilesNeedRetry = false;

function showSelection() {
  readout.textContent = point ? point.join(", ") : "";
  confirm.disabled = !point || !tilesReady;
}

function selectLocation(latLng) {
  const { lng, lat } = map.wrapLatLng(latLng);
  point = gcoord.transform([lng, lat], gcoord.WGS84, gcoord.GCJ02).map(value => value.toFixed(7));
  marker.setLatLng([lat, lng]).addTo(map);
  showSelection();
}

function createMap() {
  const container = dialog.querySelector("[data-hospital-map]");
  map = L.map(container, { doubleClickZoom: false });
  tiles = L.tileLayer("https://tile.openstreetmap.org/{z}/{x}/{y}.png", {
    maxZoom: 19,
    attribution: '&copy; <a href="https://www.openstreetmap.org/copyright">OpenStreetMap</a>',
  });
  tiles.on("loading", () => {
    tilesReady = false;
    status.textContent = "正在加载地图…";
    showSelection();
  });
  tiles.on("tileload", () => {
    tilesReady = true;
    status.textContent = "";
    showSelection();
  });
  tiles.on("tileerror", () => {
    tilesNeedRetry = true;
  });
  tiles.on("load", () => {
    if (!tilesReady) status.textContent = "地图加载失败，请稍后重试。";
  });
  tiles.addTo(map);
  marker = L.marker([0, 0], {
    draggable: true,
    alt: "门诊入口",
    icon: L.icon({
      iconUrl: container.dataset.markerIcon,
      iconRetinaUrl: container.dataset.markerRetinaIcon,
      shadowUrl: container.dataset.markerShadow,
      iconSize: [25, 41],
      iconAnchor: [12, 41],
      shadowSize: [41, 41],
    }),
  });
  map.on("click", ({ latlng }) => {
    if (tilesReady) selectLocation(latlng);
  });
  marker.on("dragend", () => selectLocation(marker.getLatLng()));
}

function fillLocation(selected) {
  [longitude.value, latitude.value] = selected || ["", ""];
  longitude.disabled = latitude.disabled = false;
  position.hidden = !selected;
  position.textContent = selected ? selected.join(", ") : "";
}

dialog.addEventListener("shown.bs.modal", () => {
  point = longitude.value && latitude.value ? [longitude.value, latitude.value] : null;
  clear.disabled = !point;
  if (!window.L || !window.gcoord) {
    status.textContent = "地图加载失败，请刷新后重试。";
    return;
  }
  if (!map) createMap();
  marker.remove();
  map.invalidateSize();
  if (point) {
    const [lng, lat] = gcoord.transform(point.map(Number), gcoord.GCJ02, gcoord.WGS84);
    map.setView([lat, lng], 18);
    marker.setLatLng([lat, lng]).addTo(map);
  } else {
    map.setView([35, 105], 4);
  }
  // Reopening at the same center leaves failed tiles in Leaflet's grid.
  if (tilesNeedRetry && !tiles.isLoading()) {
    tilesNeedRetry = false;
    tiles.redraw();
  }
  showSelection();
});

confirm.addEventListener("click", () => fillLocation(point));
clear.addEventListener("click", () => fillLocation(null));
