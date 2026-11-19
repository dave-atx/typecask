// A type term in an article, an <abbr> with the glossary's definition as its title, shows the definition in
// a popover under it on a tap, a click or Enter: a touch screen never shows a title. Without script, or a
// browser without popovers, the title is still there.
(() => {
  const pop = document.getElementById("term-pop");
  if (!pop || !pop.showPopover) return;
  const [name, text] = [pop.querySelector("strong"), pop.querySelector("p")];
  let shown = null;

  for (const term of document.querySelectorAll("abbr.term")) {
    // The popover says it now; a title would show a second copy on hover.
    term.dataset.definition = term.title;
    term.removeAttribute("title");
    term.setAttribute("aria-haspopup", "dialog");
  }

  const show = (term) => {
    if (shown === term && pop.matches(":popover-open")) {
      pop.hidePopover();
      return;
    }
    name.textContent = term.dataset.term;
    text.textContent = term.dataset.definition;
    pop.showPopover();
    // Under the term, from its start, kept inside the window.
    const at = term.getBoundingClientRect();
    const width = pop.offsetWidth;
    const left = Math.min(Math.max(8, at.left - 16), window.innerWidth - width - 8);
    const below = at.bottom + 8 + pop.offsetHeight < window.innerHeight;
    pop.style.left = `${left}px`;
    pop.style.top = `${below ? at.bottom + 8 : at.top - 8 - pop.offsetHeight}px`;
    shown = term;
  };

  document.addEventListener("click", (event) => {
    const term = event.target.closest("abbr.term");
    if (term) show(term);
  });
  document.addEventListener("keydown", (event) => {
    const term = event.target.closest?.("abbr.term");
    if (term && (event.key === "Enter" || event.key === " ")) {
      event.preventDefault();
      show(term);
    }
  });
  // Fixed to the window, so it would drift off its term on a scroll.
  addEventListener("scroll", () => pop.matches(":popover-open") && pop.hidePopover(), { passive: true });
  pop.addEventListener("toggle", (event) => {
    if (event.newState === "closed") shown = null;
  });
})();
