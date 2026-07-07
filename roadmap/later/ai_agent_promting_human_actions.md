When an ai-agent has a set of tools via server tools and the humans hava another (similar) set it would be nice to have the agent know about the actions the ai is not allowed to do but can ask the human to do (so the frontend can dynamically create a button that will do that action).

A tesl developer could write this feature by adding a tool to return some json format that the frontend renders as a button in some why. The question is if this should have first class language support.

The benefit to have it as a part of the language is to have a easy way to create safer ai-driven systems. It is also part of "1 way to do something" - instead of every developer creates their own solution to this common problem.

The negative is that it potentially bloat the language.