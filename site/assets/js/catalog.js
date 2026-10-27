// The specimen wall: load each row's face when it comes near the viewport, and filter and sort in
// place. 2,193 rows is far too many to download 2,193 fonts for, and far too few to need a server.
(function () {
    "use strict";

    // Each row carries the file its face lives in. A FontFace is added once and never again, so a
    // row that scrolls out and back costs nothing.
    var loaded = Object.create(null);

    function loadFace(el) {
        var slug = el.dataset.f;
        var file = el.dataset.p;
        if (!slug || !file || loaded[slug]) return;
        loaded[slug] = true;
        try {
            var face = new FontFace("tc-" + slug, 'url("/p/' + encodeURIComponent(file) + '")');
            face.load().then(function (f) {
                document.fonts.add(f);
            }, function () {
                // A preview that won't load leaves the row in the system face, which still reads.
            });
        } catch (e) {
            // No FontFace constructor: every row keeps the fallback, and the page still works.
        }
    }

    var rows = [].slice.call(document.querySelectorAll("[data-f][data-p]"));

    if ("IntersectionObserver" in window) {
        // A generous margin so a face is ready by the time the row is actually on screen.
        var io = new IntersectionObserver(function (entries) {
            entries.forEach(function (entry) {
                if (!entry.isIntersecting) return;
                loadFace(entry.target);
                io.unobserve(entry.target);
            });
        }, { rootMargin: "600px 0px" });
        rows.forEach(function (row) {
            io.observe(row);
        });
    } else {
        rows.forEach(loadFace);
    }

    // ---- filtering and sorting, catalog page only ----

    var wall = document.getElementById("wall");
    var q = document.getElementById("q");
    if (!wall || !q) return;

    var sortSelect = document.getElementById("sort");
    var countEl = document.getElementById("count");
    var emptyEl = document.getElementById("empty");
    var clearEl = document.getElementById("clear");
    var chips = [].slice.call(document.querySelectorAll(".chip[data-style], .chip[data-nerd]"));
    var all = [].slice.call(wall.children);
    var total = all.length;

    var state = { q: "", style: "", nerd: false, sort: "popularity" };

    function format(n) {
        return n.toLocaleString();
    }

    function matches(row) {
        if (state.nerd && row.dataset.nerd !== "1") return false;
        if (state.style && row.dataset.style !== state.style) return false;
        if (state.q && row.dataset.name.indexOf(state.q) === -1) return false;
        return true;
    }

    function compare(a, b) {
        switch (state.sort) {
            case "name":
                return a.dataset.name < b.dataset.name ? -1 : a.dataset.name > b.dataset.name ? 1 : 0;
            case "installs":
                return Number(b.dataset.installs) - Number(a.dataset.installs);
            case "trending":
                return Number(a.dataset.trending) - Number(b.dataset.trending);
            case "bytes":
                return Number(a.dataset.bytes) - Number(b.dataset.bytes);
            default:
                return Number(a.dataset.popularity || 0) - Number(b.dataset.popularity || 0);
        }
    }

    // The wall arrives in popularity order, so only a change of sort moves anything.
    var painted = "popularity";

    function apply() {
        var shown = 0;
        var i;

        if (state.sort !== painted) {
            // Reordering 2,193 nodes costs one reflow when they go out and come back together.
            var order = all.slice().sort(compare);
            var frag = document.createDocumentFragment();
            for (i = 0; i < order.length; i++) frag.appendChild(order[i]);
            wall.appendChild(frag);
            painted = state.sort;
        }

        for (i = 0; i < all.length; i++) {
            var ok = matches(all[i]);
            all[i].hidden = !ok;
            if (ok) shown++;
        }

        countEl.textContent = shown === total
            ? format(total) + " fonts"
            : format(shown) + " of " + format(total) + " fonts";
        emptyEl.hidden = shown !== 0;
        var filtering = Boolean(state.q || state.style || state.nerd);
        clearEl.hidden = !filtering;
        writeURL();
    }

    function writeURL() {
        if (!window.history || !window.history.replaceState) return;
        var params = new URLSearchParams();
        if (state.q) params.set("q", state.q);
        if (state.style) params.set("style", state.style);
        if (state.nerd) params.set("nerd", "1");
        if (state.sort !== "popularity") params.set("sort", state.sort);
        var qs = params.toString();
        history.replaceState(null, "", qs ? "?" + qs : location.pathname);
    }

    function readURL() {
        var params = new URLSearchParams(location.search);
        state.q = (params.get("q") || "").toLowerCase();
        state.style = params.get("style") || "";
        state.nerd = params.get("nerd") === "1";
        state.sort = params.get("sort") || "popularity";
        q.value = params.get("q") || "";
        if (sortSelect) sortSelect.value = state.sort;
        paintChips();
    }

    function paintChips() {
        chips.forEach(function (chip) {
            var on = chip.dataset.nerd
                ? state.nerd
                : chip.dataset.style === state.style && !state.nerd;
            chip.classList.toggle("is-on", on);
        });
    }

    var typing;
    q.addEventListener("input", function () {
        clearTimeout(typing);
        typing = setTimeout(function () {
            state.q = q.value.trim().toLowerCase();
            apply();
        }, 120);
    });

    chips.forEach(function (chip) {
        chip.addEventListener("click", function () {
            if (chip.dataset.nerd) {
                state.nerd = !state.nerd;
                if (state.nerd) state.style = "";
            } else {
                state.style = chip.dataset.style;
                state.nerd = false;
            }
            paintChips();
            apply();
        });
    });

    if (sortSelect) {
        sortSelect.addEventListener("change", function () {
            state.sort = sortSelect.value;
            apply();
        });
    }

    clearEl.addEventListener("click", function () {
        state.q = "";
        state.style = "";
        state.nerd = false;
        q.value = "";
        paintChips();
        apply();
    });

    readURL();
    apply();
}());
