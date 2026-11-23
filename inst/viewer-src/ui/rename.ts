// A name edited in place, on a double-click in a list (annotations, saved
// selections): the text gives way to a box holding the name, taken on Enter or
// leaving the box, dropped on Escape. `problem()` says what is wrong with a
// name (empty, taken), shown while typing; a name with one, or the same name,
// changes nothing. `done()` runs after either, once the text is back.
export function editName(text: HTMLElement, current: string, problem: (name: string) => string | null,
  commit: (name: string) => void, done: () => void): void {
  const box = Object.assign(document.createElement('input'), {
    className: 'name-edit', type: 'text', value: current, spellcheck: false, autocomplete: 'off' });
  let finished = false;
  const finish = (take: boolean) => {
    if (finished) return;
    finished = true;
    const name = box.value.trim();
    box.replaceWith(text);
    if (take && name !== current && !problem(name)) commit(name);
    done();
  };
  box.addEventListener('input', () => {
    const p = problem(box.value.trim());
    box.classList.toggle('invalid', !!p);
    box.title = p ?? '';
  });
  // Its keys are its own: not the page's shortcuts (C clears the selection)
  box.addEventListener('keydown', e => {
    e.stopPropagation();
    if (e.key === 'Enter') finish(true);
    else if (e.key === 'Escape') finish(false);
  });
  box.addEventListener('blur', () => finish(true));
  for (const t of ['click', 'dblclick', 'mousedown'] as const) box.addEventListener(t, e => e.stopPropagation());
  text.replaceWith(box);
  box.focus();
  box.select();
}
