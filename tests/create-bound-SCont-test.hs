import LwConc.Substrate
import GHC.Conc

main = do
  let task = print "TASK DONE"
  s <- newBoundSCont task
  putStrLn "Main done"
