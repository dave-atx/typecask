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

    // The wall arrives in popularity order. sorted is the rows in the chosen order; painted is the
    // order of the rows showing, as last put in the DOM, so a change that keeps it moves nothing.
    var sorted = all;
    var sortedBy = "popularity";
    var painted = all;

    function sameRows(a, b) {
        if (a.length !== b.length) return false;
        for (var i = 0; i < a.length; i++) {
            if (a[i] !== b[i]) return false;
        }
        return true;
    }

    // announce is false for the first paint, which only restores what the URL asked for.
    function apply(announce) {
        var i;
        var resorted = state.sort !== sortedBy;
        if (resorted) {
            sorted = all.toSorted(compare);
            sortedBy = state.sort;
        }

        // Name matches above description matches, each in the chosen order.
        var tiers = [[], [], []];
        for (i = 0; i < sorted.length; i++) {
            var r = rank(sorted[i]);
            sorted[i].hidden = r < 0;
            if (r >= 0) tiers[r].push(sorted[i]);
        }
        var order = tiers[0].concat(tiers[1], tiers[2]);
        var shown = order.length;

        if (!sameRows(order, painted)) {
            // Moving the rows that show costs one reflow when they go out and come back together.
            // Hidden rows keep their places, out of sight; clearing the filters brings back every row.
            var frag = document.createDocumentFragment();
            for (i = 0; i < order.length; i++) frag.appendChild(order[i]);
            wall.appendChild(frag);
            painted = order;
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
