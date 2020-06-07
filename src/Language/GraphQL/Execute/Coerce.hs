{-# LANGUAGE ExplicitForAll #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Types and functions used for input and result coercion.
module Language.GraphQL.Execute.Coerce
    ( VariableValue(..)
    , coerceInputLiteral
    , matchFieldValues
    ) where

import qualified Data.Aeson as Aeson
import Data.HashMap.Strict (HashMap)
import qualified Data.HashMap.Strict as HashMap
import qualified Data.Text.Lazy as Text.Lazy
import qualified Data.Text.Lazy.Builder as Text.Builder
import qualified Data.Text.Lazy.Builder.Int as Text.Builder
import Data.Scientific (toBoundedInteger, toRealFloat)
import Language.GraphQL.AST (Name)
import qualified Language.GraphQL.Type.In as In
import Language.GraphQL.Type.Definition

-- | Since variables are passed separately from the query, in an independent
-- format, they should be first coerced to the internal representation used by
-- this implementation.
class VariableValue a where
    -- | Only a basic, format-specific, coercion must be done here. Type
    -- correctness or nullability shouldn't be validated here, they will be
    -- validated later. The type information is provided only as a hint.
    --
    -- For example @GraphQL@ prohibits the coercion from a 't:Float' to an
    -- 't:Int', but @JSON@ doesn't have integers, so whole numbers should be
    -- coerced to 't:Int` when receiving variables as a JSON object. The same
    -- holds for 't:Enum'. There are formats that support enumerations, @JSON@
    -- doesn't, so the type information is given and 'coerceVariableValue' can
    -- check that an 't:Enum' is expected and treat the given value
    -- appropriately. Even checking whether this value is a proper member of the
    -- corresponding 't:Enum' type isn't required here, since this can be
    -- checked independently.
    --
    -- Another example is an @ID@. @GraphQL@ explicitly allows to coerce
    -- integers and strings to @ID@s, so if an @ID@ is received as an integer,
    -- it can be left as is and will be coerced later.
    --
    -- If a value cannot be coerced without losing information, 'Nothing' should
    -- be returned, the coercion will fail then and the query won't be executed.
    coerceVariableValue
        :: In.Type -- ^ Expected type (variable type given in the query).
        -> a -- ^ Variable value being coerced.
        -> Maybe Value -- ^ Coerced value on success, 'Nothing' otherwise.

instance VariableValue Aeson.Value where
    coerceVariableValue _ Aeson.Null = Just Null
    coerceVariableValue (In.ScalarBaseType scalarType) value
        | (Aeson.String stringValue) <- value = Just $ String stringValue
        | (Aeson.Bool booleanValue) <- value = Just $ Boolean booleanValue
        | (Aeson.Number numberValue) <- value
        , (ScalarType "Float" _) <- scalarType =
            Just $ Float $ toRealFloat numberValue
        | (Aeson.Number numberValue) <- value = -- ID or Int
            Int <$> toBoundedInteger numberValue
    coerceVariableValue (In.EnumBaseType _) (Aeson.String stringValue) =
        Just $ Enum stringValue
    coerceVariableValue (In.InputObjectBaseType objectType) value
        | (Aeson.Object objectValue) <- value = do
            let (In.InputObjectType _ _ inputFields) = objectType
            (newObjectValue, resultMap) <- foldWithKey objectValue inputFields
            if HashMap.null newObjectValue
                then Just $ Object resultMap
                else Nothing
      where
        foldWithKey objectValue = HashMap.foldrWithKey matchFieldValues'
            $ Just (objectValue, HashMap.empty)
        matchFieldValues' _ _ Nothing = Nothing
        matchFieldValues' fieldName inputField (Just (objectValue, resultMap)) =
            let (In.InputField _ fieldType _) = inputField
                insert = flip (HashMap.insert fieldName) resultMap
                newObjectValue = HashMap.delete fieldName objectValue
             in case HashMap.lookup fieldName objectValue of
                    Just variableValue -> do
                        coerced <- coerceVariableValue fieldType variableValue
                        pure (newObjectValue, insert coerced)
                    Nothing -> Just (objectValue, resultMap)
    coerceVariableValue (In.ListBaseType listType) value
        | (Aeson.Array arrayValue) <- value = List
            <$> foldr foldVector (Just []) arrayValue
        | otherwise = coerceVariableValue listType value
      where
        foldVector _ Nothing = Nothing
        foldVector variableValue (Just list) = do
            coerced <- coerceVariableValue listType variableValue
            pure $ coerced : list 
    coerceVariableValue _ _ = Nothing

-- | Looks up a value by name in the given map, coerces it and inserts into the
-- result map. If the coercion fails, returns 'Nothing'. If the value isn't
-- given, but a default value is known, inserts the default value into the
-- result map. Otherwise it fails with 'Nothing' if the Input Type is a
-- Non-Nullable type, or returns the unchanged, original map.
matchFieldValues :: forall a
    . (In.Type -> a -> Maybe Value)
    -> HashMap Name a
    -> Name
    -> In.Type
    -> Maybe Value
    -> Maybe (HashMap Name Value)
    -> Maybe (HashMap Name Value)
matchFieldValues coerce values' fieldName type' defaultValue resultMap =
    case HashMap.lookup fieldName values' of
        Just variableValue -> coerceRuntimeValue $ coerce type' variableValue
        Nothing
            | Just value <- defaultValue ->
                HashMap.insert fieldName value <$> resultMap
            | Nothing <- defaultValue
            , In.isNonNullType type' -> Nothing
            | otherwise -> resultMap
  where
    coerceRuntimeValue (Just Null)
        | In.isNonNullType type' = Nothing
    coerceRuntimeValue coercedValue =
        HashMap.insert fieldName <$> coercedValue <*> resultMap

-- | Coerces operation arguments according to the input coercion rules for the
-- corresponding types.
coerceInputLiteral :: In.Type -> Value -> Maybe Value
coerceInputLiteral (In.ScalarBaseType type') value
    | (String stringValue) <- value
    , (ScalarType "String" _) <- type' = Just $ String stringValue
    | (Boolean booleanValue) <- value
    , (ScalarType "Boolean" _) <- type' = Just $ Boolean booleanValue
    | (Int intValue) <- value
    , (ScalarType "Int" _) <- type' = Just $ Int intValue
    | (Float floatValue) <- value
    , (ScalarType "Float" _) <- type' = Just $ Float floatValue
    | (Int intValue) <- value
    , (ScalarType "Float" _) <- type' =
        Just $ Float $ fromIntegral intValue
    | (String stringValue) <- value
    , (ScalarType "ID" _) <- type' = Just $ String stringValue
    | (Int intValue) <- value
    , (ScalarType "ID" _) <- type' = Just $ decimal intValue
  where
    decimal = String
        . Text.Lazy.toStrict
        . Text.Builder.toLazyText
        . Text.Builder.decimal
coerceInputLiteral (In.EnumBaseType type') (Enum enumValue)
    | member enumValue type' = Just $ Enum enumValue
  where
    member value (EnumType _ _ members) = HashMap.member value members
coerceInputLiteral (In.InputObjectBaseType type') (Object values) = 
    let (In.InputObjectType _ _ inputFields) = type'
        in Object
            <$> HashMap.foldrWithKey (matchFieldValues' values) (Just HashMap.empty) inputFields
  where
    matchFieldValues' values' fieldName (In.InputField _ inputFieldType defaultValue) =
        matchFieldValues coerceInputLiteral values' fieldName inputFieldType defaultValue
coerceInputLiteral _ _ = Nothing