#lang racket

(raise-user-error 'dsl/trusted
                  "internal-only module; application code should use the DSL's public checker/auther surfaces or specific trusted helpers instead")
