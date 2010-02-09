import Network.Socket (withSocketsDo)
import Test.Framework (defaultMain)
import qualified Array
import qualified Manager
import qualified PSQ

main :: IO ()
main = withSocketsDo $ defaultMain tests
  where tests = [ Array.tests
                , Manager.tests
                , PSQ.tests
                ]
