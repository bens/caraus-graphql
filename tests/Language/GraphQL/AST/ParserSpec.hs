{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE QuasiQuotes #-}
module Language.GraphQL.AST.ParserSpec
    ( spec
    ) where

import Data.List.NonEmpty (NonEmpty(..))
import Language.GraphQL.AST.Document
import qualified Language.GraphQL.AST.DirectiveLocation as DirLoc
import Language.GraphQL.AST.Parser
import Test.Hspec (Spec, describe, it)
import Test.Hspec.Megaparsec (shouldParse, shouldFailOn, shouldSucceedOn)
import Text.Megaparsec (parse)
import Text.RawString.QQ (r)

spec :: Spec
spec = describe "Parser" $ do
    it "accepts BOM header" $
        parse document "" `shouldSucceedOn` "\xfeff{foo}"

    it "accepts block strings as argument" $
        parse document "" `shouldSucceedOn` [r|{
              hello(text: """Argument""")
            }|]

    it "accepts strings as argument" $
        parse document "" `shouldSucceedOn` [r|{
              hello(text: "Argument")
            }|]

    it "accepts two required arguments" $
        parse document "" `shouldSucceedOn` [r|
            mutation auth($username: String!, $password: String!){
              test
            }|]

    it "accepts two string arguments" $
        parse document "" `shouldSucceedOn` [r|
            mutation auth{
              test(username: "username", password: "password")
            }|]

    it "accepts two block string arguments" $
        parse document "" `shouldSucceedOn` [r|
            mutation auth{
              test(username: """username""", password: """password""")
            }|]

    it "parses minimal schema definition" $
        parse document "" `shouldSucceedOn` [r|schema { query: Query }|]

    it "parses minimal scalar definition" $
        parse document "" `shouldSucceedOn` [r|scalar Time|]

    it "parses ImplementsInterfaces" $
        parse document "" `shouldSucceedOn` [r|
            type Person implements NamedEntity & ValuedEntity {
              name: String
            }
        |]

    it "parses a  type without ImplementsInterfaces" $
        parse document "" `shouldSucceedOn` [r|
            type Person {
              name: String
            }
        |]

    it "parses ArgumentsDefinition in an ObjectDefinition" $
        parse document "" `shouldSucceedOn` [r|
            type Person {
              name(first: String, last: String): String
            }
        |]

    it "parses minimal union type definition" $
        parse document "" `shouldSucceedOn` [r|
            union SearchResult = Photo | Person
        |]

    it "parses minimal interface type definition" $
        parse document "" `shouldSucceedOn` [r|
            interface NamedEntity {
              name: String
            }
        |]

    it "parses minimal enum type definition" $
        parse document "" `shouldSucceedOn` [r|
            enum Direction {
              NORTH
              EAST
              SOUTH
              WEST
            }
        |]

    it "parses minimal enum type definition" $
        parse document "" `shouldSucceedOn` [r|
            enum Direction {
              NORTH
              EAST
              SOUTH
              WEST
            }
        |]

    it "parses minimal input object type definition" $
        parse document "" `shouldSucceedOn` [r|
            input Point2D {
              x: Float
              y: Float
            }
        |]

    it "parses minimal input enum definition with an optional pipe" $
        parse document "" `shouldSucceedOn` [r|
            directive @example on
              | FIELD
              | FRAGMENT_SPREAD
        |]

    it "parses two minimal directive definitions" $
        let directive nm loc =
                TypeSystemDefinition
                    (DirectiveDefinition
                         (Description Nothing)
                         nm
                         (ArgumentsDefinition [])
                         (loc :| []))
            example1 =
                directive "example1"
                    (DirLoc.TypeSystemDirectiveLocation DirLoc.FieldDefinition)
                    (Location {line = 2, column = 17})
            example2 =
                directive "example2"
                    (DirLoc.ExecutableDirectiveLocation DirLoc.Field)
                    (Location {line = 3, column = 17})
            testSchemaExtension = example1 :| [ example2 ]
            query = [r|
                directive @example1 on FIELD_DEFINITION
                directive @example2 on FIELD
            |]
         in parse document "" query `shouldParse` testSchemaExtension

    it "parses a directive definition with a default empty list argument" $
        let directive nm loc args =
                TypeSystemDefinition
                    (DirectiveDefinition
                         (Description Nothing)
                         nm
                         (ArgumentsDefinition
                              [ InputValueDefinition
                                    (Description Nothing)
                                    argName
                                    argType
                                    argValue
                                    []
                              | (argName, argType, argValue) <- args])
                         (loc :| []))
            defn =
                directive "test"
                    (DirLoc.TypeSystemDirectiveLocation DirLoc.FieldDefinition)
                    [("foo",
                      TypeList (TypeNamed "String"),
                      Just
                          $ Node (ConstList [])
                          $ Location {line = 1, column = 33})]
                    (Location {line = 1, column = 1})
            query = [r|directive @test(foo: [String] = []) on FIELD_DEFINITION|]
         in parse document "" query `shouldParse` (defn :| [ ])

    it "parses schema extension with a new directive" $
        parse document "" `shouldSucceedOn`[r|
            extend schema @newDirective
        |]

    it "parses schema extension with an operation type definition" $
        parse document "" `shouldSucceedOn` [r|extend schema { query: Query }|]

    it "parses schema extension with an operation type and directive" $
        let newDirective = Directive "newDirective" [] $ Location 1 15
            schemaExtension = SchemaExtension
                $ SchemaOperationExtension [newDirective]
                $ OperationTypeDefinition Query "Query" :| []
            testSchemaExtension = TypeSystemExtension schemaExtension
                $ Location 1 1
            query = [r|extend schema @newDirective { query: Query }|]
         in parse document "" query `shouldParse` (testSchemaExtension :| [])

    it "parses an object extension" $
        parse document "" `shouldSucceedOn` [r|
            extend type Story {
              isHiddenLocally: Boolean
            }
        |]

    it "rejects variables in DefaultValue" $
        parse document "" `shouldFailOn` [r|
            query ($book: String = "Zarathustra", $author: String = $book) {
              title
            }
        |]

    it "parses documents beginning with a comment" $
        parse document "" `shouldSucceedOn` [r|
            """
            Query
            """
            type Query {
                queryField: String
            }
        |]

    it "parses subscriptions" $
        parse document "" `shouldSucceedOn` [r|
            subscription NewMessages {
              newMessage(roomId: 123) {
                sender
              }
            }
        |]
