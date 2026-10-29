const session = 'browser-' + crypto.randomUUID();
const byId = id => document.getElementById(id);
const state = { products: [], orders: [] };
const money = value => new Intl.NumberFormat('en-US', { style: 'currency', currency: 'USD' }).format(value);
async function api(path, options) {
  const response = await fetch(path, Object.assign({}, options || {}, { headers: Object.assign({ 'content-type': 'application/json', 'x-northstar-session': session }, options && options.headers) }));
  const data = await response.json();
  if (!response.ok) throw new Error(data.error || 'Request failed');
  return data;
}
function toast(message) { const element = byId('toast'); element.textContent = message; element.classList.add('show'); clearTimeout(toast.timer); toast.timer = setTimeout(() => element.classList.remove('show'), 3400); }
function element(tag, className, content) { const node = document.createElement(tag); if (className) node.className = className; if (content !== undefined) node.textContent = content; return node; }
function showProducts(products) {
  const root = byId('products'); root.replaceChildren();
  if (!products.length) root.append(element('p', 'muted', 'No products matched that search.'));
  products.forEach(product => {
    const card = element('article', 'product');
    card.append(element('div', 'eyebrow', product.category), element('h3', '', product.name), element('p', '', product.description), element('div', 'price', money(product.price)));
    const actions = element('div', 'product-actions');
    const details = element('button', 'secondary', 'Explore');
    const add = element('button', '', 'Add to cart');
    details.onclick = () => inspect(product.id);
    add.onclick = () => addCart(product.id);
    actions.append(details, add); card.append(actions); root.append(card);
  });
}
function showCart(data) {
  const root = byId('cart'); root.replaceChildren();
  if (!data.items.length) root.append(element('p', 'muted', 'Add something to begin a checkout trace.'));
  data.items.forEach(item => { const line = element('div', 'cart-line'); line.append(element('span', '', item.name + ' × ' + item.quantity), element('strong', '', money(item.price * item.quantity))); root.append(line); });
  byId('totals').textContent = data.items.length ? 'Total ' + money(data.total) + ' · tax ' + money(data.tax) : '';
}
function showOrders(orders) {
  state.orders = orders; const root = byId('orders'); root.replaceChildren();
  if (!orders.length) root.append(element('p', 'muted', 'Orders you place can be fulfilled here.'));
  orders.forEach(order => {
    const line = element('div', 'order-line'), left = element('div', '');
    left.append(element('strong', '', order.id), document.createElement('br'), element('small', 'muted', order.customer + ' · ' + money(order.total)));
    const right = element('div', ''); right.append(element('div', 'pill', order.status));
    if (order.status === 'Paid') { const button = element('button', '', 'Fulfill'); button.style.marginTop = '7px'; button.style.padding = '6px 8px'; button.style.fontSize = '11px'; button.onclick = () => advance(order.id); right.append(button); }
    if (order.status === 'Shipped') { const button = element('button', 'secondary', 'Return'); button.style.marginTop = '7px'; button.style.padding = '6px 8px'; button.style.fontSize = '11px'; button.onclick = () => startReturn(order.id); right.append(button); }
    line.append(left, right); root.append(line);
  });
}
function showDetail(data) {
  const root = byId('detail'), product = data.product; root.classList.add('visible'); root.replaceChildren();
  root.append(element('div', 'eyebrow', product.category), element('h2', '', product.name), element('p', 'muted', product.description));
  const grid = element('div', 'detail-grid');
  grid.append(element('div', '', 'Loaded product, review aggregation, inventory availability, and related recommendations in parallel.'), element('div', '', 'Related: ' + data.related.map(item => item.name).join(', ')));
  root.append(grid);
}
function showFeed(data) {
  const root = byId('feed'); root.replaceChildren(); byId('feed-status').textContent = data.collector.replace('/v1/traces', '') + ' · ' + data.profile;
  if (!data.activity.length) root.append(element('li', 'muted', 'Your request traces will appear here.'));
  data.activity.forEach(item => {
    const row = element('li', ''), status = element('span', item.status >= 400 ? 'pill error' : 'pill', item.status >= 400 ? 'Error' : 'OK');
    row.append(element('strong', '', item.route), element('span', '', item.spans + ' spans'), element('span', '', item.duration + 'ms'), status);
    root.append(row);
  });
}
async function refresh(includeOrders) {
  const tasks = [api('/api/cart'), api('/api/activity')]; if (includeOrders) tasks.push(api('/api/orders'));
  const results = await Promise.all(tasks); showCart(results[0]); showFeed(results[1]); if (includeOrders) showOrders(results[2].orders);
}
async function addCart(id) { try { const data = await api('/api/cart', { method: 'POST', body: JSON.stringify({ productId: id }) }); showCart(data); await refresh(false); toast('Added to cart. Inspect the new trace: catalog, reservation, pricing, tax, cart, and analytics.'); } catch (error) { toast(error.message); } }
async function inspect(id) { try { showDetail(await api('/api/products/' + id)); await refresh(false); toast('Product exploration completed with three concurrent downstream reads.'); } catch (error) { toast(error.message); } }
async function advance(id) { try { const data = await api('/api/orders/' + id + '/advance', { method: 'POST' }); showOrders(state.orders.map(order => order.id === data.order.id ? data.order : order)); await refresh(false); toast('Order shipped. The fulfillment trace includes warehouse allocation, carrier label, and event publishing.'); } catch (error) { toast(error.message); } }
async function startReturn(id) { try { const data = await api('/api/orders/' + id + '/return', { method: 'POST' }); showOrders(state.orders.map(order => order.id === data.order.id ? data.order : order)); await refresh(false); toast('Return initiated. Inspect the reverse-logistics trace: refund, carrier return label, restock, and notifications.'); } catch (error) { toast(error.message); } }
byId('search-button').onclick = async () => { try { const data = await api('/api/search?q=' + encodeURIComponent(byId('search').value)); showProducts(data.products); await refresh(false); } catch (error) { toast(error.message); } };
byId('search').onkeydown = event => { if (event.key === 'Enter') byId('search-button').click(); };
byId('all-button').onclick = () => showProducts(state.products);
byId('checkout-button').onclick = () => byId('checkout-form').classList.toggle('visible');
byId('checkout-form').onsubmit = async event => { event.preventDefault(); try { const data = await api('/api/checkout', { method: 'POST', body: JSON.stringify({ customer: byId('customer').value }) }); byId('checkout-form').classList.remove('visible'); byId('customer').value = ''; await refresh(true); toast('Order ' + data.order.id + ' placed. This is the largest trace in the app: authorization, fraud, carrier fan-out, order transaction, outbox, and notifications.'); } catch (error) { toast(error.message); } };
byId('orders-button').onclick = () => document.getElementById('orders').scrollIntoView({ behavior: 'smooth', block: 'center' });
byId('profile').onchange = async event => { try { await api('/api/profile', { method: 'PUT', body: JSON.stringify({ profile: event.target.value }) }); toast('Operating profile updated. Your next application action will reflect it.'); await refresh(false); } catch (error) { toast(error.message); } };
async function boot() { try { const data = await api('/api/products'); state.products = data.products; showProducts(data.products); await refresh(true); } catch (error) { toast(error.message); } }
boot();
