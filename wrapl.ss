(import :std/actor
        :std/format
        (except-in :std/sugar hash)
        :thunknyc/hash
        :thunknyc/sugar)

(defproto wrapl
  id: wrapl
  event: (request req)                 ; ->request
         (cancel id)                   ; ->cancel
         (response res)                ; response->
         (exit wait?)                  ; ->exit
         (will-exit))                  ; will-exit->

(def (process-request @source handler req)
  (try
   (let (res (handler req))
     (!!wrapl.response @source res))
   (catch (exc)
     (!!wrapl.response @source (hash (type 'exception) (req req))))))

(def max-request-seconds (make-parameter 10))

(def (worker-finished? w)
  (let (s (thread-state w))
    (or (thread-state-abnormally-terminated? s)
        (thread-state-normally-terminated? s))))

(def (monitor-process @source req worker)
  (let (start-seconds (time->seconds (current-time)))
   (let lp ((now-seconds (time->seconds (current-time))))
     (cond ((worker-finished? worker)
            (eprintf "Completed:\n~S\n" req))
           ((> (- now-seconds start-seconds) (max-request-seconds))
            (thread-terminate! worker)
            (eprintf "Terminated due to timeout:\n~S\n" req)
            (!!wrapl.response @source (hash (type 'timeout) (req req))))
           (else
            (thread-sleep! 0.5)
            (lp (time->seconds (current-time))))))))

(def (wrapl-server handler)
  (try
   (let lp ()
     (<- ((!wrapl.exit wait?)
          (when wait? (thread-sleep! (max-request-seconds)))
          (!!wrapl.will-exit @source))
         ;; fall through and therefore exit

         ((!wrapl.request req)
          (let* ((worker
                  (make-thread (cut process-request @source handler req)))
                 (monitor
                  (make-thread (cut monitor-process @source worker))))
            (thread-start! worker)
            (thread-start! monitor))
          (!!wrapl.response @source (hash (type 'received) (req req)))
          (lp))))
   (catch (e)
     (eprintf "An internal exception occurred:\n ~S\n" e))))

(def wrapl-service (spawn wrapl-server))

;; TODO: Send a event-not-processed response.
(def root-handler
  (lambda (req reply)
    (reply (hash (type 'ignored) (req req)))))

;; TODO: Turn all the pomp and circumstance into a HANDLER macro.
(def wrap-eval-handler
  (lambda (next)
    (lambda (req reply)
      (match req
        ((hash (type 'eval) (body form))
         (eprintf "An eval request:\n~S\n" form)
         (reply (eval form)))
        ((hash (type t))
         (eprintf "Some other request of type ~S:\n~S\n" t req)
         (next req reply))))))

(def handler (wrap-eval-handler root-handler))
