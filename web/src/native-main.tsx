import { StrictMode } from 'react';
import { createRoot } from 'react-dom/client';
import { NativeApp } from './NativeApp.tsx';
import './styles.css';

const root = document.getElementById('root');
if (!root) throw new Error('Bex root element is missing.');
createRoot(root).render(<StrictMode><NativeApp /></StrictMode>);
