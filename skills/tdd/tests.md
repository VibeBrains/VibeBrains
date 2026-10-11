# Хорошие и плохие тесты

## Хорошие

**В духе интеграционных**: проверяют через настоящие интерфейсы, а не через подмены внутренних частей.

```typescript
// GOOD: Tests observable behavior
test("user can checkout with valid cart", async () => {
  const cart = createCart();
  cart.add(product);
  const result = await checkout(cart, paymentMethod);
  expect(result.status).toBe("confirmed");
});
```

Признаки:

- проверяет поведение, важное пользователю или вызывающему коду
- пользуется только публичным интерфейсом
- переживает внутренний рефакторинг
- описывает ЧТО, а не КАК
- одно логическое утверждение на тест

## Плохие

**Тесты деталей реализации**: привязаны к внутреннему устройству.

```typescript
// BAD: Tests implementation details
test("checkout calls paymentService.process", async () => {
  const mockPayment = jest.mock(paymentService);
  await checkout(cart, payment);
  expect(mockPayment.process).toHaveBeenCalledWith(cart.total);
});
```

Тревожные признаки:

- подменены внутренние участники
- тестируются приватные методы
- утверждения о числе и порядке вызовов
- тест ломается при рефакторинге без смены поведения
- имя теста описывает КАК, а не ЧТО
- проверка идёт внешним путём, а не через интерфейс

```typescript
// BAD: Bypasses interface to verify
test("createUser saves to database", async () => {
  await createUser({ name: "Alice" });
  const row = await db.query("SELECT * FROM users WHERE name = ?", ["Alice"]);
  expect(row).toBeDefined();
});

// GOOD: Verifies through interface
test("createUser makes user retrievable", async () => {
  const user = await createUser({ name: "Alice" });
  const retrieved = await getUser(user.id);
  expect(retrieved.name).toBe("Alice");
});
```

**Тавтологические тесты**: ожидаемое значение повторяет реализацию, и тест проходит по построению.

```typescript
// BAD: Expected value is recomputed the way the code computes it
test("calculateTotal sums line items", () => {
  const items = [{ price: 10 }, { price: 5 }];
  const expected = items.reduce((sum, i) => sum + i.price, 0);
  expect(calculateTotal(items)).toBe(expected);
});

// GOOD: Expected value is an independent, known literal
test("calculateTotal sums line items", () => {
  expect(calculateTotal([{ price: 10 }, { price: 5 }])).toBe(15);
});
```
