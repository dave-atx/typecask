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
    var statusEl = document.getElementById("status");
    var chips = [].slice.call(document.querySelectorAll(".chip[data-style], .chip[data-nerd]"));
    var all = [].slice.call(wall.children);
    var total = all.length;

    var state = { q: "", terms: [], style: "", nerd: false, sort: "popularity" };

    // Each description's distinct words by slug, from the file section.html writes. Fetched the
    // first time someone searches, since it outweighs the page; until it arrives, search reads names.
    var words = null;
    var wordsRequested = false;

    function loadWords() {
        if (wordsRequested || !q.dataset.words || !window.fetch) return;
        wordsRequested = true;
        fetch(q.dataset.words)
            .then(function (response) { return response.ok ? response.json() : null; })
            .then(function (json) {
                if (!json) return;
                words = json;
                if (state.terms.length) apply(false);
            })
            .catch(function () {});
    }

    function setQuery(value) {
        state.q = value.trim().toLowerCase();
        // Words separated by spaces are alternatives, so "rubik gidole" shows both to compare.
        state.terms = state.q.split(/\s+/).filter(function (term, i, terms) {
            return term && terms.indexOf(term) === i;
        });
    }

    // What the status line says the order is, when a change of sort is what happened.
    var orderNames = {
        popularity: "Most popular first",
        trending: "Climbing fastest first",
        name: "By name",
        bytes: "Smallest first"
    };

    function format(n) {
        return n.toLocaleString();
    }

    // Where a row ranks for the filters, or -1 when it doesn't match: 0 when its name holds the whole
    // query or is one of the words, so "rubik gidole" leads with Rubik and Gidole before Rubik's
    // dozens of display cuts; 1 when its name holds any of the words; 2 when only its description
    // does. A description match needs three letters, so the first letters typed don't match nearly
    // every description.
    function rank(row) {
        if (state.nerd && row.dataset.nerd !== "1") return -1;
        if (state.style && row.dataset.style !== state.style) return -1;
        if (!state.terms.length) return 0;
        var name = row.dataset.name;
        if (name.indexOf(state.q) !== -1 || state.terms.indexOf(name) !== -1) return 0;
        var i;
        for (i = 0; i < state.terms.length; i++) {
            if (name.indexOf(state.terms[i]) !== -1) return 1;
        }
        var text = words && words[row.dataset.f];
        if (text) {
            for (i = 0; i < state.terms.length; i++) {
                if (state.terms[i].length > 2 && text.indexOf(state.terms[i]) !== -1) return 2;
            }
        }
        return -1;
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

    // The wall arrives in popularity order, and stays in the chosen sort's order but for the rows a
    // search lifts above or drops below the rest. Moving rows in the page is what costs: Safari has
    // taken 5 seconds to move the whole wall. So a filter only hides rows, a search moves the fewest
    // it can, and every move happens with the wall out of the document (detached, below). sorted is
    // the rows in the chosen order; above and below are the rows a search moved to the top and the
    // bottom of the wall, in the order they're there.
    var sorted = all;
    var sortedBy = "popularity";
    var above = [];
    var below = [];

    function sameRows(a, b) {
        if (a.length !== b.length) return false;
        for (var i = 0; i < a.length; i++) {
            if (a[i] !== b[i]) return false;
        }
        return true;
    }

    // Puts the rows a search moved back where the sort has them. From the end, so the row each goes
    // before is already in its place.
    function restore() {
        if (!above.length && !below.length) return;
        var moved = new Set(above.concat(below));
        for (var i = sorted.length - 1; i >= 0; i--) {
            if (moved.has(sorted[i])) wall.insertBefore(sorted[i], sorted[i + 1] || null);
        }
        above = [];
        below = [];
    }

    // Runs moves on the wall out of the document. In place, Safari's cost grows with each row moved
    // among rows that show, to seconds for a few hundred; detached, the moves are cheap and putting
    // the wall back costs one layout. Nothing reads layout in between, so the scroll stays put.
    function detached(moves) {
        var parent = wall.parentNode;
        var next = wall.nextSibling;
        parent.removeChild(wall);
        moves();
        parent.insertBefore(wall, next);
    }

    function place(rows, before) {
        if (!rows.length) return;
        var frag = document.createDocumentFragment();
        for (var i = 0; i < rows.length; i++) frag.appendChild(rows[i]);
        wall.insertBefore(frag, before);
    }

    // announce is false for the first paint, which only restores what the URL asked for.
    function apply(announce) {
        var i;
        var resorted = state.sort !== sortedBy;
        if (resorted) {
            sorted = all.toSorted(compare);
            sortedBy = state.sort;
            above = [];
            below = [];
            detached(function () {
                place(sorted, null);
            });
        }

        // Name matches above description matches, each in the chosen order.
        var tiers = [[], [], []];
        var ranks = new Array(sorted.length);
        for (i = 0; i < sorted.length; i++) {
            ranks[i] = rank(sorted[i]);
            if (ranks[i] >= 0) tiers[ranks[i]].push(sorted[i]);
        }
        var shown = tiers[0].length + tiers[1].length + tiers[2].length;

        // The biggest tier stays where the sort has it; the tiers ranked before it go to the top of
        // the wall and the ones after it to the bottom. Hidden rows between them show nothing.
        var keep = 0;
        for (i = 1; i < 3; i++) {
            if (tiers[i].length > tiers[keep].length) keep = i;
        }
        var nextAbove = [].concat.apply([], tiers.slice(0, keep));
        var nextBelow = [].concat.apply([], tiers.slice(keep + 1));
        if (!sameRows(nextAbove, above) || !sameRows(nextBelow, below)) {
            detached(function () {
                restore();
                // Before the first row that stays: a row going to the top can't be what it goes before.
                var lifted = new Set(nextAbove);
                var first = wall.firstChild;
                while (first && lifted.has(first)) first = first.nextSibling;
                place(nextAbove, first);
                place(nextBelow, null);
            });
            above = nextAbove;
            below = nextBelow;
        }

        // Shown and hidden after the moves, and only where that changes.
        for (i = 0; i < sorted.length; i++) {
            var hide = ranks[i] < 0;
            if (sorted[i].hidden !== hide) sorted[i].hidden = hide;
        }

        var count = shown === total
            ? format(total) + " fonts"
            : format(shown) + " of " + format(total) + " fonts";
        countEl.textContent = count;
        if (announce && statusEl) {
            statusEl.textContent = resorted && orderNames[state.sort]
                ? orderNames[state.sort] + ". " + count + "."
                : count + ".";
        }
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
        setQuery(params.get("q") || "");
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
            chip.setAttribute("aria-pressed", String(on));
        });
    }

    var typing;
    q.addEventListener("input", function () {
        clearTimeout(typing);
        typing = setTimeout(function () {
            setQuery(q.value);
            if (state.terms.length) loadWords();
            apply(true);
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
            apply(true);
        });
    });

    if (sortSelect) {
        sortSelect.addEventListener("change", function () {
            state.sort = sortSelect.value;
            apply(true);
        });
    }

    clearEl.addEventListener("click", function () {
        setQuery("");
        state.style = "";
        state.nerd = false;
        q.value = "";
        paintChips();
        apply(true);
    });

    q.addEventListener("focus", loadWords);

    readURL();
    if (state.terms.length) loadWords();
    apply(false);
}());
