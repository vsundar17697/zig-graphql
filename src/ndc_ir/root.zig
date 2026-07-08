//! Pure query IR shared by graphql_parser and query_builder: no I/O, no Postgres awareness.
//! See docs/architecture.md for why this module has zero dependencies and zero consumers'
//! awareness of how a Query value was produced.

const query = @import("query.zig");
const expression = @import("expression.zig");
const order_by = @import("order_by.zig");
const relationship = @import("relationship.zig");
const aggregate = @import("aggregate.zig");
const mutation = @import("mutation.zig");

pub const Query = query.Query;
pub const Field = query.Field;
pub const ColumnField = query.ColumnField;
pub const RelationshipField = query.RelationshipField;
pub const FieldSelection = query.FieldSelection;
pub const RelationshipMap = query.RelationshipMap;
pub const AggregateSelection = query.AggregateSelection;
pub const VariableSet = query.VariableSet;

pub const Aggregate = aggregate.Aggregate;
pub const AggregateFunction = aggregate.AggregateFunction;

pub const Expression = expression.Expression;
pub const BinaryComparison = expression.BinaryComparison;
pub const UnaryComparison = expression.UnaryComparison;
pub const ComparisonTarget = expression.ComparisonTarget;
pub const ComparisonValue = expression.ComparisonValue;
pub const ScalarValue = expression.ScalarValue;
pub const BinaryOperator = expression.BinaryOperator;
pub const UnaryOperator = expression.UnaryOperator;
pub const binaryOperatorFromName = expression.binaryOperatorFromName;
pub const ExistsExpression = expression.ExistsExpression;
pub const ExistsInCollection = expression.ExistsInCollection;

pub const OrderByElement = order_by.OrderByElement;
pub const OrderDirection = order_by.OrderDirection;

pub const Relationship = relationship.Relationship;
pub const RelationshipType = relationship.RelationshipType;
pub const RelationshipColumnMapping = relationship.ColumnMapping;

pub const MutationOperation = mutation.MutationOperation;
pub const MutationRequest = mutation.MutationRequest;
pub const ArgumentMap = mutation.ArgumentMap;

test {
    @import("std").testing.refAllDecls(@This());
}
