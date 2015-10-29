{-# LANGUAGE BangPatterns #-}

module Main where

import Control.Concurrent.STM
import Criterion.Main
import Data.List (foldl')
import System.Random

import qualified ArrayOfQueue as A
import qualified ArrayOfQueueIO as AIO
import qualified BinaryHeap as B
import qualified BinaryHeapIO as BIO
import qualified Heap as O
import qualified Network.HTTP2.Priority.PSQ as P
import qualified RandomSkewHeap as R

type Key = Int
type Weight = Int

numOfStreams :: Int
numOfStreams = 100

numOfTrials :: Int
numOfTrials = 10000

main :: IO ()
main = do
    gen <- getStdGen
    let ks = [1,3..]
        ws = take numOfStreams $ randomRs (1,256) gen
        xs = zip ks ws
    defaultMain [
        bgroup "enqueue & dequeue" [
              bench "Random Skew Heap"      $ whnf enqdeqR xs
            , bench "Okasaki Heap"          $ whnf enqdeqO xs
            , bench "Priority Search Queue" $ whnf enqdeqP xs
            , bench "Binary Heap STM"       $ nfIO (enqdeqB ws)
            , bench "Binary Heap IO"        $ nfIO (enqdeqBIO xs)
            , bench "Array of Queue STM"    $ nfIO (enqdeqA xs)
            , bench "Array of Queue IO"     $ nfIO (enqdeqAIO xs)
            ]
      , bgroup "delete" [
              bench "Random Skew Heap"      $ whnf deleteR xs
            , bench "Okasaki Heap"          $ whnf deleteO xs
            , bench "Priority Search Queue" $ whnf deleteP xs
            , bench "Binary Heap IO"        $ nfIO (deleteBIO xs)
            , bench "Array of Queue IO"     $ nfIO (deleteAIO xs)
            ]
      ]

----------------------------------------------------------------

enqdeqR :: [(Key,Weight)] -> ()
enqdeqR xs = loop pq numOfTrials
  where
    !pq = createR xs R.empty
    loop _ 0  = ()
    loop q !n = case R.dequeue q of
        Nothing         -> error "enqdeqR"
        Just (k,w,x,q') -> let !q'' = R.enqueue k w x q'
                           in loop q'' (n - 1)

deleteR :: [(Key,Weight)] -> R.PriorityQueue Int
deleteR xs = foldl' (\p k -> snd (R.delete k p)) pq ks
  where
    !pq = createR xs R.empty
    (ks,_) = unzip xs

createR :: [(Key,Weight)] -> R.PriorityQueue Int -> R.PriorityQueue Int
createR [] !q = q
createR ((k,w):xs) !q = createR xs q'
  where
    !q' = R.enqueue k w k q

----------------------------------------------------------------

enqdeqO :: [(Key,Weight)] -> O.PriorityQueue Int
enqdeqO xs = loop pq numOfTrials
  where
    !pq = createO xs O.empty
    loop !q  0 = q
    loop !q !n = case O.dequeue q of
        Nothing -> error "enqdeqO"
        Just (k,w,x,q') -> loop (O.enqueue k w x q') (n - 1)

deleteO :: [(Key,Weight)] -> O.PriorityQueue Int
deleteO xs = foldl' (\p k -> snd (O.delete k p)) pq ks
  where
    !pq = createO xs O.empty
    (ks,_) = unzip xs

createO :: [(Key,Weight)] -> O.PriorityQueue Int -> O.PriorityQueue Int
createO [] !q = q
createO ((k,w):xs) !q = createO xs q'
  where
    !q' = O.enqueue k w k q

----------------------------------------------------------------

enqdeqP :: [(Key,Weight)] -> P.PriorityQueue Int
enqdeqP xs = loop pq numOfTrials
  where
    !pq = createP xs P.empty
    loop !q 0  = q
    loop !q !n = case P.dequeue q of
        Nothing -> error "enqdeqP"
        Just (k,w,x,q') -> loop (P.enqueue k w x q') (n - 1)

deleteP :: [(Key,Weight)] -> P.PriorityQueue Int
deleteP xs = foldl' (\p k -> snd (P.delete k p)) pq ks
  where
    !pq = createP xs P.empty
    (ks,_) = unzip xs

createP :: [(Key,Weight)] -> P.PriorityQueue Int -> P.PriorityQueue Int
createP [] !q = q
createP ((k,w):xs) !q = createP xs (P.enqueue k w k q)

----------------------------------------------------------------

enqdeqB :: [Weight] -> IO ()
enqdeqB xs = do
    q <- atomically (B.new numOfStreams)
    createB xs q
    loop q numOfTrials
  where
    loop _ 0  = return ()
    loop q !n = do
        ent <- atomically $ B.dequeue q
        atomically $ B.enqueue ent q
        loop q (n - 1)

createB :: [Weight] -> B.PriorityQueue Int -> IO ()
createB [] _      = return ()
createB (x:xs) !q = do
    let !ent = B.newEntry x x
    atomically $ B.enqueue ent q
    createB xs q

----------------------------------------------------------------

enqdeqBIO :: [(Key,Weight)] -> IO ()
enqdeqBIO xs = do
    q <- BIO.new numOfStreams
    createBIO xs q
    loop q numOfTrials
  where
    loop _ 0  = return ()
    loop q !n = do
        (k,w,x) <- BIO.dequeue q
        BIO.enqueue k w x q
        loop q (n - 1)

deleteBIO :: [(Key,Weight)] -> IO ()
deleteBIO xs = do
    q <- BIO.new numOfStreams
    createBIO xs q
    mapM_ (\k -> BIO.delete k q) keys
  where
    (keys,_) = unzip xs

createBIO :: [(Key,Weight)] -> BIO.PriorityQueue Int -> IO ()
createBIO [] _      = return ()
createBIO ((k,w):xs) !q = do
    BIO.enqueue k w k q
    createBIO xs q

----------------------------------------------------------------

enqdeqA :: [(Key,Weight)] -> IO ()
enqdeqA xs = do
    q <- atomically A.new
    createA xs q
    loop q numOfTrials
  where
    loop _ 0  = return ()
    loop q !n = do
        Just (k,w,x) <- atomically $ A.dequeue q
        atomically $ A.enqueue k w x q
        loop q (n - 1)

createA :: [(Key,Weight)] -> A.PriorityQueue Int -> IO ()
createA [] _      = return ()
createA ((k,w):xs) !q = do
    atomically $ A.enqueue k w k q
    createA xs q

----------------------------------------------------------------

enqdeqAIO :: [(Key,Weight)] -> IO ()
enqdeqAIO xs = do
    q <- AIO.new
    createAIO xs q
    loop q numOfTrials
  where
    loop _ 0  = return ()
    loop q !n = do
        Just (k,w,x) <- AIO.dequeue q
        AIO.enqueue k w x q
        loop q (n - 1)

deleteAIO :: [(Key,Weight)] -> IO ()
deleteAIO xs = do
    q <- AIO.new
    createAIO xs q
    mapM_ (\k -> AIO.delete k q) keys
  where
    (keys,_) = unzip xs

createAIO :: [(Key,Weight)] -> AIO.PriorityQueue Int -> IO ()
createAIO [] _      = return ()
createAIO ((k,w):xs) !q = do
    AIO.enqueue k w k q
    createAIO xs q

----------------------------------------------------------------
