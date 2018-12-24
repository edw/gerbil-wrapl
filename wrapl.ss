(import :std/actor
        :std/format
        :std/sugar
        :std/iter)

(defproto wrapl
  id: wrapl
  event: (request xid req)                 ; ->request
         (cancel xid)                      ; ->cancel
         (receipt xid)                     ; receipt->
         (exception xid message irritants) ; exception->
         (response xid res)                ; response->
         (timeout xid)                     ; timeout->
         (exit wait?)                      ; ->exit
         (will-exit))                      ; will-exit->

;; A request is not a bare form to eval, though that's what this dummy
;; code treats it as. Instead, evaluation will be but one of several
;; request types. Completion, namespace manipulation, middleware
;; management should be handled through a let's say plist-based
;; request structure. A piece of middleware will have two hooks: a
;; request processing hook and a response processing hook, allowing
;; middleware to decorate both incoming requests and outgoing
;; responses.
(def (process-request @source xid req)
  (try
   (let (res (eval req))
     (!!wrapl.response @source xid res))
   (catch (exc)
     (!!wrapl.exception @source xid exc `(,req)))))

(define max-request-seconds (make-parameter 10))

(def (worker-finished? w)
  (let (s (thread-state w))
    (or (thread-state-abnormally-terminated? s)
        (thread-state-normally-terminated? s))))

(def (monitor-process @source xid worker)
  (let (start-seconds (time->seconds (current-time)))
   (let lp ((now-seconds (time->seconds (current-time))))
     (cond ((worker-finished? worker)
            (eprintf "Request ~S complete\n" xid))
           ((> (- now-seconds start-seconds) (max-request-seconds))
            (thread-terminate! worker)
            (eprintf "Terminated ~S due to timeout\n" xid)
            (!!wrapl.timeout @source xid))
           (else
            (thread-sleep! 0.5)
            (lp (time->seconds (current-time))))))))

(def (wrapl-server)
  (try
   (let lp ()
     (<- ((!wrapl.exit wait?)
          (when wait? (thread-sleep! (max-request-seconds)))
          (!!wrapl.will-exit @source))
         ;; fall through and therefore exit

         ((!wrapl.request xid req)
          (let* ((worker
                  (make-thread (cut process-request @source xid req)))
                 (monitor
                  (make-thread (cut monitor-process @source xid worker))))
            (thread-start! worker)
            (thread-start! monitor))
          (!!wrapl.receipt @source xid)
          (lp))))
   (catch (e)
     (eprintf "An internal exception occurred:\n ~S\n" e))))

(def wrapl-service (spawn wrapl-server))

(def handle-eval
  (match <...>
    ([xid ['request (? (hash-ref body 'type #f) => 'eval)]]
     (eprintf "An eval request:\nxid: ~S\nbody: ~S\n" xid body))
    ([xid event] (eprintf "Something else:\nxid: ~S\nevent: ~S\n" xid event))))
