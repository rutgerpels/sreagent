/* ContosoPay checkout — client logic (served from 'self' to satisfy CSP). */
(function () {
  'use strict';

  var payBtn = document.getElementById('pay');
  var autoBox = document.getElementById('auto');
  var resultEl = document.getElementById('result');
  var statusText = document.getElementById('status-text');
  var statusDot = document.getElementById('status-dot');
  var timer = null;

  function setStatus(ok, text) {
    statusText.textContent = text;
    statusDot.className = 'dot ' + (ok ? 'ok' : 'bad');
  }

  function placeOrder() {
    setStatus(true, 'Placing order…');
    return fetch('/api/checkout', {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ amount: 49.99, currency: 'EUR' })
    })
      .then(function (r) {
        return r.json().then(function (data) {
          return { ok: r.ok, data: data };
        });
      })
      .then(function (res) {
        resultEl.textContent = JSON.stringify(res.data, null, 2);
        setStatus(res.ok, res.ok ? 'Order confirmed' : 'Order failed');
      })
      .catch(function (err) {
        resultEl.textContent = String(err);
        setStatus(false, 'Network error');
      });
  }

  payBtn.addEventListener('click', placeOrder);

  autoBox.addEventListener('change', function () {
    if (autoBox.checked) {
      placeOrder();
      timer = setInterval(placeOrder, 2000);
    } else if (timer) {
      clearInterval(timer);
      timer = null;
    }
  });
})();
