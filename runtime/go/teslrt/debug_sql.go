package teslrt

import (
	"strconv"
	"strings"
)

func DebugPgSql(plan PgPlan) PgPlan {
	wrapped := PgPlan{
		SQL: plan.SQL,
		Args: func() []any {
			arguments := plan.arguments()
			params := make([]DebugValue, len(arguments))
			for index, argument := range arguments {
				params[index] = debugValueOf(argument)
			}
			operation, table := debugSQLMetadata(plan.SQL)
			SetDebugSQLCapture(&DebugSQLCapture{
				Operation: operation, SQL: plan.SQL, Params: params, Table: table,
				Preview: debugSQLPreview(plan.SQL, params),
			})
			return arguments
		},
	}
	wrapped.Capture = func(rowCount int) { updateDebugSQLRowCount(rowCount) }
	return wrapped
}

func updateDebugSQLRowCount(rowCount int) {
	debugState.Lock()
	if debugState.sql != nil {
		debugState.sql.RowCount = rowCount
	}
	debugState.Unlock()
}

func debugSQLMetadata(statement string) (string, string) {
	words := strings.Fields(statement)
	if len(words) == 0 {
		return "", ""
	}
	operation := strings.ToLower(strings.Trim(words[0], "\"`;,()"))
	for index, word := range words {
		switch strings.ToLower(strings.Trim(word, "\"`;,()")) {
		case "from", "into", "update", "table":
			if index+1 < len(words) {
				return operation, strings.Trim(words[index+1], "\"`;,()")
			}
		}
	}
	return operation, ""
}

func debugSQLPreview(statement string, params []DebugValue) string {
	var preview strings.Builder
	for index := 0; index < len(statement); {
		if statement[index] != '$' {
			preview.WriteByte(statement[index])
			index++
			continue
		}
		end := index + 1
		for end < len(statement) && statement[end] >= '0' && statement[end] <= '9' {
			end++
		}
		if end == index+1 {
			preview.WriteByte(statement[index])
			index++
			continue
		}
		parameter, err := strconv.Atoi(statement[index+1 : end])
		if err != nil || parameter < 1 || parameter > len(params) {
			preview.WriteString(statement[index:end])
			index = end
			continue
		}
		param := params[parameter-1]
		literal := "'" + strings.ReplaceAll(param.Display, "'", "''") + "'"
		preview.WriteString(literal)
		index = end
	}
	return preview.String()
}
