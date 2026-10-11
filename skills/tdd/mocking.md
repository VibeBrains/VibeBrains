# Когда подменять зависимости

Подменять только на **границах системы**:

- внешние API (платежи, почта и подобное)
- базы данных (иногда — лучше тестовая база)
- время и случайность
- файловая система (иногда)

Не подменять:

- собственные классы и модули
- внутренних участников
- всё, чем управляете сами

## Проектировать под подмену

На границах системы интерфейсы делают такими, чтобы их было легко подменить.

**1. Внедрение зависимостей**

Внешнюю зависимость передают внутрь, а не создают внутри:

```typescript
// Easy to mock
function processPayment(order, paymentClient) {
  return paymentClient.charge(order.total);
}

// Hard to mock
function processPayment(order) {
  const client = new StripeClient(process.env.STRIPE_KEY);
  return client.charge(order.total);
}
```

**2. Интерфейс в духе SDK вместо универсального запроса**

На каждую внешнюю операцию — своя функция, а не одна общая с условной логикой:

```typescript
// GOOD: Each function is independently mockable
const api = {
  getUser: (id) => fetch(`/users/${id}`),
  getOrders: (userId) => fetch(`/users/${userId}/orders`),
  createOrder: (data) => fetch('/orders', { method: 'POST', body: data }),
};

// BAD: Mocking requires conditional logic inside the mock
const api = {
  fetch: (endpoint, options) => fetch(endpoint, options),
};
```

Что это даёт:

- каждая подмена возвращает одну определённую форму
- в подготовке теста нет условной логики
- видно, какие точки входа тест затрагивает
- типы проверяются по каждой точке отдельно
