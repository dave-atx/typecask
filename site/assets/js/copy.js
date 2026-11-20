// The Copy button beside a command, shown only where the clipboard can take it.
for (const button of document.querySelectorAll("button.copy[data-copy]")) {
  if (!navigator.clipboard) continue;
  button.hidden = false;
  button.addEventListener("click", async () => {
    try {
      await navigator.clipboard.writeText(button.dataset.copy);
      button.textContent = "Copied";
    } catch {
      button.textContent = "Couldn't copy";
    }
    setTimeout(() => (button.textContent = "Copy"), 2000);
  });
}
