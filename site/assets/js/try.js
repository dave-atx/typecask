// Try It Out on a font page: a text box set in the font's own faces, loaded from the release's web fonts
// on R2 only once someone asks, with each face, a slider for each axis and the ligatures switchable.
(() => {
  const section = document.querySelector(".try");
  if (!section) return;
  const data = JSON.parse(section.querySelector(".try-data").textContent);
  const start = section.querySelector(".try-start");
  const editor = section.querySelector(".try-editor");
  const text = section.querySelector(".try-text");
  const status = section.querySelector(".try-status");
  const style = section.querySelector(".try-style select");
  const size = section.querySelector(".try-size");
  const axes = section.querySelector(".try-axes");
  const ligatures = section.querySelector(".try-liga");
  const loads = new Map();
  let variations = {};

  // The face nearest regular to start with: upright, weight closest to 400.
  let face = data.faces.reduce((best, f, i) => {
    const score = (g) => (g.italic ? 1000 : 0) + Math.abs(g.weight - 400);
    return score(f) < score(data.faces[best]) ? i : best;
  }, 0);

  data.faces.forEach((f, i) => style.add(new Option(f.name, String(i), i === face, i === face)));

  const load = (i) => {
    if (!loads.has(i)) {
      const font = new FontFace(`tc-try-${i}`, `url("${data.base}${data.faces[i].file}")`);
      loads.set(i, font.load().then((loaded) => document.fonts.add(loaded)));
    }
    return loads.get(i);
  };

  const apply = () => {
    text.style.fontFamily = `"tc-try-${face}", var(--ui)`;
    text.style.fontSize = `${size.value}px`;
    text.style.fontVariationSettings =
      Object.entries(variations).map(([tag, value]) => `"${tag}" ${value}`).join(", ") || "normal";
    text.style.fontVariantLigatures = !ligatures || ligatures.checked ? "normal" : "none";
  };

  const showAxes = () => {
    axes.replaceChildren();
    variations = {};
    for (const axis of data.faces[face].axes) {
      const label = document.createElement("label");
      const input = document.createElement("input");
      Object.assign(input, {
        type: "range",
        min: axis.min,
        max: axis.max,
        step: axis.max - axis.min > 20 ? 1 : 0.1,
        value: axis.default,
      });
      input.addEventListener("input", () => {
        variations[axis.tag] = input.value;
        apply();
      });
      label.append(`${axis.name} `, input);
      axes.append(label);
    }
  };

  const show = async () => {
    status.textContent = "Loading…";
    try {
      await load(face);
      status.textContent = "";
    } catch {
      status.textContent = "The font couldn't be loaded. Try again later.";
    }
    showAxes();
    apply();
  };

  start.addEventListener("click", async () => {
    start.hidden = true;
    editor.hidden = false;
    text.value = data.text;
    await show();
    text.focus({ preventScroll: true });
  });
  style.addEventListener("change", () => {
    face = Number(style.value);
    show();
  });
  size.addEventListener("input", apply);
  ligatures?.addEventListener("change", apply);
})();
