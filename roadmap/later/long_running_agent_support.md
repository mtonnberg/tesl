# Long running agent support

## Background

We have first class support for ai chat + tool use. The chat can also be picked up at a later time (after a slow job on a queue is completed for instance). But we do not have support for an autonomous agent running in its own context/container. Think how temportal.ai supports. The use cases could be
    - ai coding agent as part of the team in a issue tracking software
    - An ai sales rep in a crm software etc
    - a product manager
    - a legal expert
    - an openclaw agent perhaps. 

## Goal

- Have good support for long running agent that run in their own container/service

## Notes

- We do not neccessarily need to implement/host/manage the agents ourselves via Tesl but it should be a breeze to hook it up if you are developing an app with Tesl. 