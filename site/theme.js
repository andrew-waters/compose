// Theme toggle. The pre-paint script in <head> resolves the initial data-theme
// from localStorage or the system preference; this owns the button afterwards.
(function () {
  var root = document.documentElement;
  function dark() { return root.getAttribute('data-theme') === 'dark'; }

  function init() {
    var btn = document.getElementById('theme-toggle');
    if (!btn) return;
    function render() { btn.textContent = dark() ? '☀︎' : '☾'; }
    render();
    btn.addEventListener('click', function () {
      root.setAttribute('data-theme', dark() ? 'light' : 'dark');
      try { localStorage.setItem('theme', root.getAttribute('data-theme')); } catch (e) {}
      render();
    });
  }

  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', init);
  else init();
})();
