To reduce the code base, language surface and make the language as focused and tight as possible I think we should remove the || proofs. It is needed to have a general solution but in practices over quite many years of working with GDP I never/rarely use it. More over, if it is needed it can be expressed as (Either (Int a::: IsPositive a) (Int b::: IsNegative b): eitherPositiveOrNegative).

Remove all code connecting to the Or proof. || should still work when comparing bools ofc.

## Note
This change should more or less only result in removed code, updated documentation and updated examples since the idea is to remove capabilities from the language and make it smaller.