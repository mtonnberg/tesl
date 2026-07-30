# Migrate from Zod to Effect-TS

## Background

Today we support client generation for Elm and Zod(typescript). Zod is popular but I think Effect-TS is better.

## Options

We could

1. Keep Zod and not add Effect-TS
2. Substitute the Zod generation with Effect-TS
3. *Add* Effect-TS so we have three clients (Elm, Zod and Effect-TS)

## Thoughts

I'm on the fence but are leaning towards no 3, adding it. However it depends on the short term and more importantly, long term costs of having yet another client
